"""Small HTTP API for the Exchange-local Windows service."""

import hmac
import json
import logging
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

from .core import OperationError, STATUS, invalid


class Handler(BaseHTTPRequestHandler):
    server_version = "ExchangeAutomation/1"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, format, *args):
        # The default handler logs raw URLs and headers. Audit only fixed fields below.
        pass

    def _send(self, status, value, request_id):
        payload = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Request-ID", request_id)
        self.end_headers()
        self.wfile.write(payload)

    def _error(self, error, request_id):
        response = {"error": error.detail(), "request_id": request_id}
        partial = getattr(error, "partial", None)
        if partial and partial.get("mailbox_id"):
            response["partial_result"] = partial
        self._send(504 if error.timeout else STATUS.get(error.code, 502), response, request_id)

    def _path(self):
        return urlsplit(self.path).path

    def do_GET(self):
        request_id = secrets.token_hex(16)
        if self._path() == "/healthz":
            self._send(200, {"status": "ok"}, request_id)
        else:
            self._send(404, {"error": "Not Found"}, request_id)

    def do_POST(self):
        request_id = secrets.token_hex(16)
        path = self._path()
        is_onboard = path == "/api/exchange/users"
        is_offboard = path.startswith("/api/exchange/users/") and path.endswith("/offboard")
        if not is_onboard and not is_offboard:
            self._send(404, {"error": "Not Found"}, request_id)
            return
        token = self.server.config.get("api_token", "")
        if token and not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
            self._send(401, {"error": {"code": "UNAUTHORIZED", "message": "Valid service bearer token required", "state_unknown": False},
                             "request_id": request_id}, request_id)
            return
        try:
            if self.headers.get("Transfer-Encoding"):
                raise invalid("chunked request bodies are not supported")
            size = int(self.headers.get("Content-Length", "0"))
            if size < 0 or size > 65536:
                raise invalid("request body must be at most 64 KiB")
            try:
                body = self.rfile.read(size)
            except OSError:
                raise invalid("incomplete request body") from None
            if len(body) != size:
                raise invalid("incomplete request body")
            if is_onboard:
                if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                    self._send(415, {"error": {"code": "INVALID_REQUEST", "message": "Content-Type must be application/json",
                                                     "state_unknown": False}, "request_id": request_id}, request_id)
                    return
                try:
                    request = json.loads(body.decode("utf-8"), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                except (UnicodeError, ValueError):
                    raise invalid("request body must be valid JSON") from None
                result = self.server.exchange.onboard(request)
                status, action = (201 if result["created"] else 200), "onboard"
            else:
                if body:
                    raise invalid("offboard does not accept a request body")
                raw_login = path[len("/api/exchange/users/"):-len("/offboard")]
                result = self.server.exchange.offboard(unquote(raw_login))
                status, action = 200, "offboard"
            self.server.logger.info("exchange_operation request_id=%s action=%s login=%s mailbox_id=%s",
                                    request_id, action, result["login_name"], result["mailbox_id"])
            self._send(status, result, request_id)
        except OperationError as exc:
            self.server.logger.warning("exchange_operation request_id=%s code=%s step=%s target=%s state_unknown=%s",
                                       request_id, exc.code, exc.step, exc.target, exc.state_unknown)
            self._error(exc, request_id)
        except (ValueError, TypeError):
            self._error(invalid("invalid request body"), request_id)
        except Exception:
            self.server.logger.exception("exchange_operation request_id=%s internal_error", request_id)
            self._send(500, {"error": {"code": "INTERNAL_ERROR", "message": "Internal server error", "state_unknown": True},
                             "request_id": request_id}, request_id)


def create_server(address, config, exchange, logger=None):
    server = ThreadingHTTPServer(address, Handler)
    server.daemon_threads = True
    server.config = config
    server.exchange = exchange
    server.logger = logger or logging.getLogger("exchange_automation")
    return server
