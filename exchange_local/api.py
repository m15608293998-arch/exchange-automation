"""Bounded WSGI API; authentication is normally provided by the Keycloak gateway."""

import hmac
import json
import logging
import secrets
import threading
from http import HTTPStatus

from waitress import create_server as waitress_server, wasyncore

from .core import OperationError, STATUS, invalid, login_name


class Application:
    def __init__(self, config, exchange, logger):
        self.config, self.exchange, self.logger = config, exchange, logger

    def __call__(self, env, start_response):
        request_id = secrets.token_hex(16)
        action, login, result = "", "", None

        def respond(status, value):
            payload = (json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode("utf-8")
            start_response(str(status) + " " + HTTPStatus(status).phrase, [
                ("Content-Type", "application/json; charset=utf-8"),
                ("Content-Length", str(len(payload))), ("X-Request-ID", request_id)])
            return [payload]

        def audit(status, error=None):
            # Only known fields: never log request bodies, passwords, tokens or raw exceptions.
            record = {"request_id": request_id, "action": action, "login": login,
                      "peer": env.get("REMOTE_ADDR", ""), "status": status, "result": result}
            if error:
                record["error"] = error.detail()
                record["error_type"] = error.error_type
            self.logger.info("exchange_operation %s", json.dumps(record, ensure_ascii=True))

        path, method = env.get("PATH_INFO", ""), env.get("REQUEST_METHOD", "")
        if path == "/healthz" and method == "GET":
            return respond(200, {"status": "ok"})
        is_onboard = path == "/api/exchange/users"
        is_offboard = path.startswith("/api/exchange/users/") and path.endswith("/offboard")
        if not is_onboard and not is_offboard:
            return respond(404, {"error": "Not Found"})
        if method != "POST":
            return respond(405, {"error": "Method Not Allowed"})
        action = "onboard" if is_onboard else "offboard"
        try:
            token = self.config.get("api_token", "")
            if token and not hmac.compare_digest(env.get("HTTP_AUTHORIZATION", "").encode("utf-8"),
                                                 ("Bearer " + token).encode("utf-8")):
                raise OperationError("UNAUTHORIZED", "Valid service bearer token required")
            size = int(env.get("CONTENT_LENGTH") or "0")
            if size < 0 or size > 65536:
                raise invalid("request body must be at most 64 KiB")
            body = env["wsgi.input"].read(size)
            if len(body) != size:
                raise invalid("incomplete request body")
            if is_onboard:
                if env.get("CONTENT_TYPE", "").split(";", 1)[0].strip().lower() != "application/json":
                    raise OperationError("UNSUPPORTED_MEDIA_TYPE", "Content-Type must be application/json")
                try:
                    request = json.loads(body.decode("utf-8"), parse_constant=reject_constant)
                except (UnicodeError, ValueError):
                    raise invalid("request body must be valid JSON") from None
                if isinstance(request, dict):
                    login = login_name(request.get("login_name"))
                result = self.exchange.onboard(request)
                status = 201 if result["created"] else 200
            else:
                if body:
                    raise invalid("offboard does not accept a request body")
                # PATH_INFO is already URL-decoded by the HTTP server; do not decode twice.
                login = login_name(path[len("/api/exchange/users/"):-len("/offboard")])
                result = self.exchange.offboard(login)
                status = 200
            audit(status)
            return respond(status, result)
        except (ValueError, TypeError, UnicodeError):
            error = invalid("invalid request body")
        except OperationError as exc:
            error = exc
        except Exception as exc:
            error = OperationError("INTERNAL_ERROR", "Internal server error", state_unknown=True,
                                   error_type=type(exc).__name__)
        result = getattr(error, "partial", None)
        status = 504 if error.timeout else STATUS.get(error.code, 502)
        audit(status, error)
        response = {"error": error.detail(), "request_id": request_id}
        if result and result.get("mailbox_id"):
            response["partial_result"] = result
        return respond(status, response)


def reject_constant(value):
    raise ValueError("non-finite JSON number")


class Server:
    def __init__(self, address, config, exchange, logger):
        self.exchange = exchange
        self._closed = threading.Event()
        self._server = waitress_server(Application(config, exchange, logger), host=address[0], port=address[1],
            threads=config.get("max_concurrent_operations", 2) + 2, connection_limit=64, backlog=64,
            max_request_body_size=65536, max_request_header_size=16384,
            channel_timeout=15, cleanup_interval=1, asyncore_loop_timeout=0.2,
            expose_tracebacks=False, ident="ExchangeAutomation")
        self.server_port = int(self._server.effective_port)

    def serve_forever(self):
        self._server.run()

    def shutdown(self):
        self.exchange.begin_stop()
        dispatcher = self._server.task_dispatcher
        dispatcher.set_thread_count(0)
        # Keep socket I/O alive while active workers finish; queued work is never executed.
        with dispatcher.lock:
            while dispatcher.threads:
                dispatcher.thread_exit_cv.wait(0.2)
        dispatcher.shutdown(timeout=0)
        self.server_close()

    def server_close(self):
        if not self._closed.is_set():
            self._closed.set()
            wasyncore.close_all(map=self._server._map, ignore_all=True)


def create_server(address, config, exchange, logger=None):
    return Server(address, config, exchange, logger or logging.getLogger("exchange_automation"))
