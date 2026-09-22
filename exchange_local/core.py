"""Request validation, orchestration and the fixed local PowerShell bridge."""

import json
import os
import re
import subprocess
import threading
import time
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path


LOGIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$")
DOMAIN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")
GUID = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
OPERATIONS = {"resolve_groups", "ensure_mailbox", "ensure_group_member", "discover_user_groups", "remove_group_member"}
MUTATIONS = {"ensure_mailbox", "ensure_group_member", "remove_group_member"}
STATUS = {
    "UNAUTHORIZED": 401, "UNSUPPORTED_MEDIA_TYPE": 415, "SERVICE_STOPPING": 503, "INTERNAL_ERROR": 500,
    "INVALID_REQUEST": 400, "USER_NOT_FOUND": 404,
    "RECIPIENT_CONFLICT": 409, "OPERATION_BUSY": 409,
    "OPERATION_STATE_UNKNOWN": 409, "GROUP_NOT_FOUND": 422,
    "GROUP_TYPE_NOT_ALLOWED": 422, "CAPACITY_EXCEEDED": 429,
    "EXCHANGE_COMMAND_FAILED": 502, "AUTOMATION_UNAVAILABLE": 502,
}


class OperationError(Exception):
    def __init__(self, code, message, *, step="", target="", state_unknown=False, timeout=False, error_type=""):
        super().__init__(message)
        self.code, self.message = code, message
        self.step, self.target = step, target
        self.state_unknown, self.timeout = state_unknown, timeout
        self.error_type = error_type

    def detail(self):
        result = {"code": self.code, "message": self.message, "state_unknown": self.state_unknown}
        if self.step:
            result["step"] = self.step
        if self.target:
            result["target"] = self.target
        return result


def invalid(message):
    return OperationError("INVALID_REQUEST", message)


def has_control(value):
    return any(unicodedata.category(char) in {"Cc", "Cs"} for char in value)


def login_name(value):
    if not isinstance(value, str):
        raise invalid("login_name is invalid")
    value = value.strip()
    if not LOGIN.fullmatch(value) or value.endswith(".") or ".." in value:
        raise invalid("login_name must be 1-20 ASCII characters, start with a letter or digit, and contain only letters, digits, dot, underscore or hyphen; trailing/consecutive dots are forbidden")
    return value.lower()


def normalize_onboard(value):
    if not isinstance(value, dict) or set(value) - {"login_name", "display_name", "initial_password", "groups"}:
        raise invalid("request body must be a JSON object with supported fields")
    login = login_name(value.get("login_name"))
    display = value.get("display_name")
    if not isinstance(display, str) or not display.strip():
        raise invalid("display_name is required")
    display = display.strip()
    if len(display) > 256 or has_control(display):
        raise invalid("display_name must be at most 256 characters and contain no control characters")
    password = value.get("initial_password", "")
    if not isinstance(password, str) or any(unicodedata.category(c) == "Cs" for c in password) or len(password.encode("utf-8")) > 1024 or "\0" in password:
        raise invalid("initial_password is invalid")
    groups = value.get("groups", [])
    if not isinstance(groups, list) or len(groups) > 100:
        raise invalid("groups must contain at most 100 entries")
    normalized, seen = [], set()
    for group in groups:
        if not isinstance(group, str):
            raise invalid("each groups entry must be a string")
        group = group.strip()
        if not group or has_control(group) or len(group.encode("utf-8")) > 512:
            raise invalid("each groups entry must be non-empty, at most 512 bytes, and contain no control characters")
        if group.casefold() not in seen:
            normalized.append(group)
            seen.add(group.casefold())
    return login, display, password, normalized


def configured(config):
    required = {"project_directory", "http_address", "mail_domain", "mailbox_database", "domain_controller", "state_directory"}
    if not isinstance(config, dict) or any(not isinstance(config.get(key), str) or not config[key].strip() for key in required):
        raise ValueError("missing required local-service configuration")
    mail_domain = config["mail_domain"].lower().lstrip("@")
    upn_suffix = config.get("upn_suffix") or mail_domain
    if not isinstance(upn_suffix, str) or not DOMAIN.fullmatch(mail_domain) or not DOMAIN.fullmatch(upn_suffix.lower()):
        raise ValueError("invalid mail domain or UPN suffix")
    for name in ("reset_password_on_next_logon", "bypass_group_manager_check"):
        if name in config and not isinstance(config[name], bool):
            raise ValueError(name + " must be a JSON boolean")
    address = config["http_address"]
    if not re.fullmatch(r"[^:]+:[0-9]{1,5}", address):
        raise ValueError("http_address must be host:port")
    host, port = address.rsplit(":", 1)
    if not 1 <= int(port) <= 65535:
        raise ValueError("invalid HTTP port")
    timeout = config.get("operation_timeout_seconds", 300)
    max_concurrent = config.get("max_concurrent_operations", 2)
    if type(timeout) is not int or not 1 <= timeout <= 1800 or type(max_concurrent) is not int or not 1 <= max_concurrent <= 32:
        raise ValueError("invalid timeout or concurrency")
    token = config.get("api_token", "")
    if not isinstance(token, str) or token and (len(token.encode("utf-8")) < 32 or not token.strip()):
        raise ValueError("api_token must be empty or at least 32 bytes")
    config = dict(config, mail_domain=mail_domain, upn_suffix=upn_suffix.lower())
    return config, (host, int(port))


class PowerShellRunner:
    def __init__(self, script, executable=None):
        self.script = Path(script).resolve()
        self.executable = executable or os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                                                     "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        if not self.script.is_file():
            raise ValueError("local Exchange PowerShell bridge is missing")

    def _invoke(self, request, seconds):
        # Spool output to temporary files, not unbounded RAM. Check output size and
        # elapsed time while the process runs; neither stderr nor stdin is logged.
        deadline = time.monotonic() + max(1, seconds)
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            with subprocess.Popen(
                [self.executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(self.script)],
                stdin=subprocess.PIPE, stdout=output, stderr=errors,
            ) as process:
                first = True
                try:
                    while True:
                        if any(os.fstat(stream.fileno()).st_size > 1024 * 1024 for stream in (output, errors)):
                            raise OSError("PowerShell output exceeded limit")
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise subprocess.TimeoutExpired(process.args, seconds)
                        try:
                            process.communicate(input=request if first else None, timeout=min(0.2, remaining))
                            break
                        except subprocess.TimeoutExpired:
                            first = False
                except BaseException:
                    process.kill()
                    process.communicate()
                    raise
                if any(os.fstat(stream.fileno()).st_size > 1024 * 1024 for stream in (output, errors)):
                    raise OSError("PowerShell output exceeded limit")
                output.seek(0)
                return subprocess.CompletedProcess(process.args, process.returncode, output.read(1024 * 1024 + 1))

    def execute(self, operation, parameters, seconds):
        if operation not in OPERATIONS:
            raise ValueError("unsupported Exchange operation")
        request = json.dumps({"operation": operation, "parameters": parameters}, ensure_ascii=False).encode("utf-8")
        try:
            process = self._invoke(request, seconds)
        except subprocess.TimeoutExpired:
            raise OperationError("AUTOMATION_UNAVAILABLE", "Exchange operation timed out; reconcile the outcome before retrying",
                                 step=operation, state_unknown=operation in MUTATIONS, timeout=True) from None
        except OSError:
            raise OperationError("AUTOMATION_UNAVAILABLE", "Local PowerShell I/O failed; reconcile any uncertain changes", step=operation,
                                 state_unknown=operation in MUTATIONS) from None
        if process.returncode != 0 or len(process.stdout) > 1024 * 1024:
            raise OperationError("AUTOMATION_UNAVAILABLE", "Local PowerShell failed; reconcile any uncertain changes",
                                 step=operation, state_unknown=operation in MUTATIONS)
        try:
            result = json.loads(process.stdout.decode("utf-8-sig"))
        except (UnicodeError, ValueError):
            result = None
        if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
            raise OperationError("AUTOMATION_UNAVAILABLE", "Exchange returned an invalid result",
                                 step=operation, state_unknown=operation in MUTATIONS)
        if not result["ok"]:
            code = result.get("code")
            if code not in STATUS:
                code = "EXCHANGE_COMMAND_FAILED"
            message = result.get("message")
            if not isinstance(message, str) or len(message) > 300:
                message = "Exchange command failed; inspect server diagnostics"
            unknown = result.get("state_unknown")
            error_type = result.get("error_type", "")
            if not isinstance(error_type, str) or not re.fullmatch(r"[A-Za-z0-9_.]{0,150}", error_type):
                error_type = ""
            raise OperationError(code, message, step=operation,
                                 state_unknown=unknown if type(unknown) is bool else operation in MUTATIONS,
                                 error_type=error_type)
        if not isinstance(result.get("data"), dict):
            raise OperationError("AUTOMATION_UNAVAILABLE", "Exchange returned an invalid result",
                                 step=operation, state_unknown=operation in MUTATIONS)
        return result["data"]


def valid_groups(data):
    groups = data.get("groups") if isinstance(data, dict) else None
    if not isinstance(groups, list):
        return None
    seen = set()
    for item in groups:
        if not isinstance(item, dict) or not isinstance(item.get("identity"), str) or not GUID.fullmatch(item["identity"]) or not isinstance(item.get("label"), str) or not item["label"]:
            return None
        key = item["identity"].lower()
        if key in seen:
            return None
        seen.add(key)
    return groups


class ExchangeService:
    def __init__(self, config, runner):
        self.config, _ = configured(config)
        self.runner = runner
        self.state = Path(self.config["state_directory"]).resolve()
        self.state.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.active = set()
        self.uncertain = set()
        self.stopping = False

    def begin_stop(self):
        with self.lock:
            self.stopping = True

    def _pending(self, login):
        # Prefix avoids Windows device names such as CON.pending / NUL.pending.
        return self.state / ("account-" + login + ".pending")

    def _acquire(self, login):
        with self.lock:
            if self.stopping:
                raise OperationError("SERVICE_STOPPING", "Service is stopping; retry later")
            if login in self.active:
                raise OperationError("OPERATION_BUSY", "Another operation is running for this user")
            if login in self.uncertain or self._pending(login).exists() or (self.state / (login + ".pending")).is_file():
                self.uncertain.add(login)
                raise OperationError("OPERATION_STATE_UNKNOWN", "An unfinished operation is recorded; reconcile before retrying", state_unknown=True)
            if len(self.active) >= self.config.get("max_concurrent_operations", 2):
                raise OperationError("CAPACITY_EXCEEDED", "Operation capacity reached; retry later")
            try:
                fd = os.open(str(self._pending(login)), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as journal:
                    json.dump({"login": login, "started_at": datetime.now(timezone.utc).isoformat()}, journal)
                    journal.flush()
                    os.fsync(journal.fileno())
            except FileExistsError:
                self.uncertain.add(login)
                raise OperationError("OPERATION_STATE_UNKNOWN", "An unfinished operation is recorded; reconcile before retrying", state_unknown=True) from None
            except OSError:
                raise OperationError("AUTOMATION_UNAVAILABLE", "Cannot record operation state") from None
            self.active.add(login)

    def _release(self, login, error):
        with self.lock:
            self.active.discard(login)
            if error and error.state_unknown:
                self.uncertain.add(login)
                return error
            try:
                self._pending(login).unlink()
            except OSError:
                self.uncertain.add(login)
                return OperationError("OPERATION_STATE_UNKNOWN", "Cannot finalize the operation journal; reconcile before retrying", state_unknown=True)
            return error

    def _run(self, operation, params, deadline):
        params = dict(params, DomainController=self.config["domain_controller"])
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise OperationError("AUTOMATION_UNAVAILABLE", "Exchange operation timed out; reconcile the outcome before retrying",
                                 step=operation, state_unknown=False, timeout=True)
        return self.runner.execute(operation, params, remaining)

    @staticmethod
    def _invalid_result(operation, target=""):
        raise OperationError("AUTOMATION_UNAVAILABLE", "Exchange returned an invalid or mismatched result",
                             step=operation, target=target, state_unknown=operation in MUTATIONS)

    def onboard(self, request):
        login, display, password, group_names = normalize_onboard(request)
        self._acquire(login)
        deadline = time.monotonic() + self.config.get("operation_timeout_seconds", 300)
        result, error = None, None
        try:
            groups = []
            if group_names:
                data = self._run("resolve_groups", {"GroupIdentities": group_names}, deadline)
                groups = valid_groups(data)
                if not groups:
                    self._invalid_result("resolve_groups")
            upn = login + "@" + self.config["upn_suffix"]
            address = login + "@" + self.config["mail_domain"]
            data = self._run("ensure_mailbox", {
                "LoginName": login, "DisplayName": display, "UserPrincipalName": upn,
                "PrimarySmtpAddress": address, "InitialPassword": password,
                "OrganizationalUnit": self.config.get("organizational_unit", ""),
                "MailboxDatabase": self.config["mailbox_database"],
                "ResetPasswordOnNextLogon": self.config.get("reset_password_on_next_logon", False),
            }, deadline)
            if (not isinstance(data.get("created"), bool) or not isinstance(data.get("mailbox_id"), str)
                    or not GUID.fullmatch(data["mailbox_id"])
                    or not isinstance(data.get("login_name"), str) or data["login_name"].lower() != login
                    or data.get("display_name") != display
                    or not isinstance(data.get("user_principal_name"), str) or data["user_principal_name"].lower() != upn
                    or not isinstance(data.get("primary_smtp_address"), str) or data["primary_smtp_address"].lower() != address):
                self._invalid_result("ensure_mailbox")
            result = {
                "login_name": data["login_name"], "mailbox_id": data["mailbox_id"], "display_name": data["display_name"],
                "user_principal_name": data["user_principal_name"], "primary_smtp_address": data["primary_smtp_address"],
                "created": data["created"], "password_applied": data["created"],
                "added_groups": [], "existing_groups": [],
            }
            for group in groups:
                try:
                    membership = self._run("ensure_group_member", {
                        "GroupIdentity": group["identity"], "MemberIdentity": result["mailbox_id"],
                        "BypassGroupManagerCheck": self.config.get("bypass_group_manager_check", True),
                    }, deadline)
                except OperationError as exc:
                    exc.target = group["identity"]
                    raise
                if (not isinstance(membership.get("added"), bool) or not isinstance(membership.get("group"), str) or not membership["group"]
                        or str(membership.get("group_id", "")).lower() != group["identity"].lower()
                        or str(membership.get("member_id", "")).lower() != result["mailbox_id"].lower()):
                    self._invalid_result("ensure_group_member", group["identity"])
                result["added_groups" if membership["added"] else "existing_groups"].append(membership["group"])
        except OperationError as exc:
            error = exc
        except Exception:
            error = OperationError("AUTOMATION_UNAVAILABLE", "Unexpected automation failure; reconcile before retrying", state_unknown=True)
        error = self._release(login, error)
        if error:
            error.partial = result
            raise error
        return result

    def offboard(self, raw_login):
        login = login_name(raw_login)
        self._acquire(login)
        deadline = time.monotonic() + self.config.get("operation_timeout_seconds", 300)
        result, error = None, None
        try:
            data = self._run("discover_user_groups", {"LoginName": login,
                "UserPrincipalName": login + "@" + self.config["upn_suffix"]}, deadline)
            groups = valid_groups(data)
            if not isinstance(data.get("mailbox_id"), str) or not GUID.fullmatch(data["mailbox_id"]) or groups is None:
                self._invalid_result("discover_user_groups")
            result = {"login_name": login, "mailbox_id": data["mailbox_id"], "removed_groups": []}
            for group in groups:
                try:
                    membership = self._run("remove_group_member", {
                        "GroupIdentity": group["identity"], "MemberIdentity": result["mailbox_id"],
                        "BypassGroupManagerCheck": self.config.get("bypass_group_manager_check", True),
                    }, deadline)
                except OperationError as exc:
                    exc.target = group["identity"]
                    raise
                if (not isinstance(membership.get("removed"), bool) or not isinstance(membership.get("group"), str) or not membership["group"]
                        or str(membership.get("group_id", "")).lower() != group["identity"].lower()
                        or str(membership.get("member_id", "")).lower() != result["mailbox_id"].lower()):
                    self._invalid_result("remove_group_member", group["identity"])
                if membership["removed"]:
                    result["removed_groups"].append(membership["group"])
            result["removed_groups"].sort()
        except OperationError as exc:
            error = exc
        except Exception:
            error = OperationError("AUTOMATION_UNAVAILABLE", "Unexpected automation failure; reconcile before retrying", state_unknown=True)
        error = self._release(login, error)
        if error:
            error.partial = result
            raise error
        return result
