"""Local orchestration for the restricted Microsoft.Exchange PSRP endpoint.

No remote scripts, Windows shell, delegation, TLS bypass or auth fallback.
Normal invocation reads a single request from stdin and returns sanitized JSON.
--check uses environment configuration and performs only metadata/read queries.
"""

import ipaddress
import json
import logging
import os
import re
import stat
import sys
import uuid
from urllib.parse import urlsplit


COMMANDS = {
    "Get-Mailbox": {"Identity", "DomainController"},
    "Get-Recipient": {"Identity", "DomainController"},
    "Get-User": {"Identity", "DomainController"},
    "New-Mailbox": {"Name", "FirstName", "Alias", "SamAccountName", "DisplayName",
                    "UserPrincipalName", "PrimarySmtpAddress", "Password",
                    "ResetPasswordOnNextLogon", "OrganizationalUnit", "Database", "DomainController"},
    "Get-DistributionGroup": {"Identity", "RecipientTypeDetails", "ResultSize", "DomainController"},
    "Get-DistributionGroupMember": {"Identity", "ResultSize", "DomainController"},
    "Add-DistributionGroupMember": {"Identity", "Member", "BypassSecurityGroupManagerCheck", "DomainController"},
    "Remove-DistributionGroupMember": {"Identity", "Member", "BypassSecurityGroupManagerCheck", "Confirm", "DomainController"},
}
WRITES = {"New-Mailbox", "Add-DistributionGroupMember", "Remove-DistributionGroupMember"}
MESSAGES = {
    "INVALID_REQUEST": "A required parameter is missing or invalid; a new account requires an initial password.",
    "USER_NOT_FOUND": "The mailbox was not found.",
    "GROUP_NOT_FOUND": "A requested distribution group was not found.",
    "GROUP_TYPE_NOT_ALLOWED": "Only ordinary static mail-enabled universal distribution groups are allowed.",
    "RECIPIENT_CONFLICT": "An existing object does not match the requested identity, address, display name or type.",
    "EXCHANGE_COMMAND_FAILED": "Exchange command failed; check endpoint, authentication, RBAC and directory connectivity.",
}


class Failure(Exception):
    def __init__(self, code="EXCHANGE_COMMAND_FAILED", error_type="", data=None):
        super().__init__(code)
        self.code, self.error_type, self.data = code, error_type, data


class RemoteFailure(Failure):
    def __init__(self, records):
        super().__init__(error_type="RemoteCommandError")
        self.records = records

    def is_absent(self):
        # Never mistake access denied, ambiguity or transport errors for absence.
        return bool(self.records) and all(
            getattr(r, "reason", "") == "ManagementObjectNotFoundException" or
            re.search(r"(^|,)ManagementObjectNotFoundException(,|$)", getattr(r, "fq_error", "") or "")
            for r in self.records
        )


def prop(obj, name, default=None):
    if isinstance(obj, dict):
        sources = [obj]
    else:
        sources = [getattr(obj, "adapted_properties", {}), getattr(obj, "extended_properties", {})]
    for source in sources:
        for key, value in source.items():
            if str(key).casefold() == name.casefold():
                return value
    return default


def value(obj, name):
    found = prop(obj, name)
    return "" if found is None else str(found)


def guid(raw):
    try:
        parsed = uuid.UUID(str(raw))
        if parsed.int:
            return str(parsed)
    except (ValueError, TypeError, AttributeError):
        pass
    raise Failure("INVALID_REQUEST")


def same(left, right):
    return str(left).casefold() == str(right).casefold()


def connection_from_env():
    return {
        "url": os.environ.get("EXCHANGE_POWERSHELL_URL", ""),
        "auth": os.environ.get("EXCHANGE_AUTH", "kerberos"),
        "username": os.environ.get("EXCHANGE_USERNAME", ""),
        "password": os.environ.get("EXCHANGE_PASSWORD", ""),
        "credential_file": os.environ.get("EXCHANGE_CREDENTIAL_FILE", ""),
    }


def normalize_ad_kerberos_username(username):
    # This worker targets AD: its DNS-domain Kerberos realm uses uppercase.
    # Normalize only the realm in an unescaped UPN, before authentication.
    # Preserve account spelling/passwords and never guess a realm from a
    # NetBIOS name, the Exchange host, or an alternative authentication method.
    if username.count("@") == 1 and "\\" not in username:
        account, realm = username.split("@")
        if account and realm:
            return account + "@" + realm.upper()
    return username


def connection_options(config):
    url = urlsplit(config.get("url", ""))
    if (url.scheme not in ("http", "https") or not url.hostname or "." not in url.hostname
            or url.username is not None or url.password is not None or url.query or url.fragment
            or url.path not in ("/PowerShell/", "/PowerShell")):
        raise Failure(error_type="InvalidEndpointConfiguration")
    try:
        ipaddress.ip_address(url.hostname)
    except ValueError:
        pass
    else:
        raise Failure(error_type="EndpointRequiresFQDN")
    auth = config.get("auth", "kerberos")
    if auth not in ("kerberos", "ntlm") or (auth == "ntlm" and url.scheme != "https"):
        raise Failure(error_type="UnsafeAuthenticationConfiguration")
    username, password = config.get("username", ""), config.get("password", "")
    if config.get("credential_file"):
        if username or password:
            raise Failure(error_type="AmbiguousCredentialConfiguration")
        # Open and inspect the same file; refuse symlinks and public-readable secrets.
        fd = os.open(config["credential_file"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > 65536:
                raise Failure(error_type="CredentialFileMustBePrivate")
            credentials = json.load(stream)
            username, password = credentials.get("username"), credentials.get("password")
    if not isinstance(username, str) or not username.strip() or not isinstance(password, str) or not password:
        raise Failure(error_type="MissingCredentials")
    if auth == "kerberos":
        username = normalize_ad_kerberos_username(username)
    return dict(server=url.hostname, port=url.port or (443 if url.scheme == "https" else 80),
                path="PowerShell/", ssl=url.scheme == "https", username=username, password=password,
                auth=auth, cert_validation=True, encryption="auto" if url.scheme == "https" else "always",
                no_proxy=True, connection_timeout=15, operation_timeout=60, read_timeout=70,
                reconnection_retries=0, negotiate_delegate=False, negotiate_service="HTTP",
                negotiate_send_cbt=True)


class Session:
    def __init__(self, config):
        from pypsrp.powershell import PowerShell, RunspacePool
        from pypsrp.serializer import TaggedValue
        from pypsrp.wsman import WSMan
        self.ps_class, self.tagged = PowerShell, TaggedValue
        self.wsman = WSMan(**connection_options(config))
        self.pool = RunspacePool(self.wsman, configuration_name="Microsoft.Exchange")
        self.capabilities = {}

    def open(self):
        self.pool.open()

    def close(self):
        try:
            self.pool.close()
        finally:
            self.wsman.close()

    def invoke(self, command, parameters):
        if command != "Get-Command" and (command not in COMMANDS or set(parameters) - COMMANDS[command]):
            raise Failure("INVALID_REQUEST")
        if command == "Get-Command" and (set(parameters) != {"Name"} or set(parameters["Name"]) - set(COMMANDS)):
            raise Failure("INVALID_REQUEST")
        ps = self.ps_class(self.pool)
        # add_cmdlet/add_parameter emits PSRP Command(IsScript=false) + typed data.
        ps.add_cmdlet(command).add_parameters(dict(parameters, ErrorAction="Stop"))
        try:
            result = ps.invoke()
            if ps.had_errors or ps.streams.error:
                raise RemoteFailure(ps.streams.error)
            # A failed/stopped pipeline without a populated error stream is not success.
            from pypsrp.complex_objects import PSInvocationState
            if ps.state != PSInvocationState.COMPLETED:
                raise Failure(error_type="IncompleteRemotePipeline")
            return result
        finally:
            # pypsrp 0.8 retains pipelines; do not retain every group's full membership
            # output in memory until the offboard operation ends.
            self.pool.pipelines.pop(ps.id, None)

    def inspect(self, names):
        output = self.invoke("Get-Command", {"Name": sorted(names)})
        for command in output:
            name = value(command, "Name")
            parameters = prop(command, "Parameters")
            if name in names and isinstance(parameters, dict):
                self.capabilities[name] = set(str(k) for k in parameters)
        if set(names) - set(self.capabilities):
            raise Failure(error_type="MissingCommandMetadata", data={"missing_commands": sorted(set(names) - set(self.capabilities))})

    def supports(self, command, parameter):
        return parameter in self.capabilities.get(command, set())

    def require(self, command, parameters):
        missing = sorted(p for p in parameters if not self.supports(command, p))
        if missing:
            raise Failure(error_type="MissingRBACParameters", data={"command": command, "missing_parameters": missing})

    def secure_string(self, text):
        # SecureString is encrypted using the PSRP session key, not converted by a remote script.
        self.pool.exchange_keys()
        return self.tagged("SS", text)


class Operations:
    def __init__(self, session, parameters):
        self.session, self.p = session, parameters
        self.mutation_started = False

    def bound(self, command, parameters):
        result = dict(parameters)
        if self.p.get("DomainController") and (
                command != "Get-Recipient" or self.session.supports(command, "DomainController")):
            result["DomainController"] = self.p["DomainController"]
        self.session.require(command, result)
        return result

    def call(self, command, **parameters):
        parameters = self.bound(command, parameters)
        if command in WRITES:
            self.mutation_started = True
        return self.session.invoke(command, parameters)

    def optional(self, command, identity):
        try:
            items = self.call(command, Identity=identity)
        except RemoteFailure as error:
            if error.is_absent():
                return None
            raise
        if len(items) > 1:
            raise Failure("RECIPIENT_CONFLICT")
        return items[0] if items else None

    def mailbox(self, identity, check_login=False):
        mailbox = self.optional("Get-Mailbox", identity)
        if mailbox is None:
            raise Failure("USER_NOT_FOUND")
        if value(mailbox, "RecipientTypeDetails") != "UserMailbox":
            raise Failure("RECIPIENT_CONFLICT")
        if check_login:
            if not same(value(mailbox, "SamAccountName"), self.p["LoginName"]) or not same(value(mailbox, "UserPrincipalName"), self.p["UserPrincipalName"]):
                raise Failure("RECIPIENT_CONFLICT")
        elif guid(value(mailbox, "Guid")) != guid(identity):
            raise Failure("RECIPIENT_CONFLICT")
        return mailbox

    def group(self, group):
        if value(group, "RecipientTypeDetails") != "MailUniversalDistributionGroup":
            raise Failure("GROUP_TYPE_NOT_ALLOWED")
        return {"identity": guid(value(group, "Guid")), "label": value(group, "PrimarySmtpAddress") or value(group, "Name")}

    def member(self, group_id, mailbox_id):
        members = self.call("Get-DistributionGroupMember", Identity=group_id, ResultSize="Unlimited")
        return any(guid(value(member, "Guid")) == mailbox_id for member in members)

    def resolve_groups(self):
        resolved = {}
        for identity in self.p.get("GroupIdentities", []):
            group = self.optional("Get-DistributionGroup", identity)
            if group is None:
                raise Failure("GROUP_NOT_FOUND")
            entry = self.group(group)
            resolved[entry["identity"]] = entry
        return {"groups": list(resolved.values())}

    def mailbox_result(self, mailbox, created):
        if (value(mailbox, "RecipientTypeDetails") != "UserMailbox"
                or not same(value(mailbox, "SamAccountName"), self.p["LoginName"])
                or not same(value(mailbox, "UserPrincipalName"), self.p["UserPrincipalName"])
                or not same(value(mailbox, "PrimarySmtpAddress"), self.p["PrimarySmtpAddress"])
                or value(mailbox, "DisplayName") != self.p["DisplayName"]):
            raise Failure("RECIPIENT_CONFLICT")
        return dict(created=created, mailbox_id=guid(value(mailbox, "Guid")),
                    login_name=value(mailbox, "SamAccountName"), display_name=value(mailbox, "DisplayName"),
                    user_principal_name=value(mailbox, "UserPrincipalName"), primary_smtp_address=value(mailbox, "PrimarySmtpAddress"))

    def ensure_mailbox(self):
        mailbox = self.optional("Get-Mailbox", self.p["LoginName"])
        if mailbox is None:
            mailbox = self.optional("Get-Mailbox", self.p["UserPrincipalName"])
        if mailbox is not None:
            return self.mailbox_result(mailbox, False)
        for command, identity in (("Get-Recipient", self.p["LoginName"]), ("Get-Recipient", self.p["PrimarySmtpAddress"]),
                                  ("Get-User", self.p["LoginName"]), ("Get-User", self.p["UserPrincipalName"])):
            if self.optional(command, identity) is not None:
                raise Failure("RECIPIENT_CONFLICT")
        if not self.p.get("InitialPassword"):
            raise Failure("INVALID_REQUEST")
        parameters = {k: self.p[k] for k in ("DisplayName", "UserPrincipalName", "PrimarySmtpAddress")}
        parameters.update({k: self.p["LoginName"] for k in ("Name", "FirstName", "Alias", "SamAccountName")})
        parameters["ResetPasswordOnNextLogon"] = self.p.get("ResetPasswordOnNextLogon", False)
        for source, target in (("OrganizationalUnit", "OrganizationalUnit"), ("MailboxDatabase", "Database")):
            if self.p.get(source):
                parameters[target] = self.p[source]
        # Verify both write and readback parameters before the first mutation.
        self.bound("New-Mailbox", dict(parameters, Password=None))
        self.bound("Get-Mailbox", {"Identity": self.p["LoginName"]})
        parameters["Password"] = self.session.secure_string(self.p["InitialPassword"])
        created = self.call("New-Mailbox", **parameters)
        if len(created) != 1:
            raise Failure(error_type="InvalidCreateResult")
        identity = guid(value(created[0], "Guid"))
        return self.mailbox_result(self.mailbox(identity), True)

    def discover_user_groups(self):
        mailbox = self.mailbox(self.p["LoginName"], check_login=True)
        mailbox_id = guid(value(mailbox, "Guid"))
        groups = self.call("Get-DistributionGroup", RecipientTypeDetails="MailUniversalDistributionGroup", ResultSize="Unlimited")
        memberships = []
        for group in groups:
            entry = self.group(group)
            if self.member(entry["identity"], mailbox_id):
                memberships.append(entry)
        return {"mailbox_id": mailbox_id, "groups": sorted(memberships, key=lambda item: item["label"])}

    def membership(self, remove=False):
        member_id, group_id = guid(self.p["MemberIdentity"]), guid(self.p["GroupIdentity"])
        self.mailbox(member_id)
        group = self.optional("Get-DistributionGroup", group_id)
        flag = "removed" if remove else "added"
        data = {"group": group_id, "group_id": group_id, "member_id": member_id, flag: False}
        if group is None:
            if not remove:
                raise Failure("GROUP_NOT_FOUND")
            return data
        entry = self.group(group)
        if entry["identity"] != group_id:
            raise Failure("RECIPIENT_CONFLICT")
        data["group"] = entry["label"]
        wanted = not remove
        if self.member(group_id, member_id) == wanted:
            return data
        command = "Remove-DistributionGroupMember" if remove else "Add-DistributionGroupMember"
        parameters = dict(Identity=group_id, Member=member_id)
        if self.p.get("BypassGroupManagerCheck", True):
            parameters["BypassSecurityGroupManagerCheck"] = True
        if remove:
            parameters["Confirm"] = False
        try:
            self.call(command, **parameters)
            data[flag] = True
        except RemoteFailure:
            # Known command error can be a concurrent external membership change.
            # Transport failures are NOT retried or swallowed.
            if self.member(group_id, member_id) != wanted:
                raise
        if self.member(group_id, member_id) != wanted:
            raise Failure(error_type="MembershipVerificationFailed")
        return data


NEEDED = {
    "resolve_groups": {"Get-DistributionGroup"},
    "ensure_mailbox": {"Get-Mailbox", "Get-Recipient", "Get-User", "New-Mailbox"},
    "discover_user_groups": {"Get-Mailbox", "Get-DistributionGroup", "Get-DistributionGroupMember"},
    "ensure_group_member": {"Get-Mailbox", "Get-DistributionGroup", "Get-DistributionGroupMember", "Add-DistributionGroupMember"},
    "remove_group_member": {"Get-Mailbox", "Get-DistributionGroup", "Get-DistributionGroupMember", "Remove-DistributionGroupMember"},
}


def check_connection(operations):
    session, p = operations.session, operations.p
    missing = []
    for command, params in COMMANDS.items():
        required = set(params)
        if not p.get("DomainController") or command == "Get-Recipient":
            required.discard("DomainController")
        if not p.get("OrganizationalUnit"):
            required.discard("OrganizationalUnit")
        if not p.get("MailboxDatabase"):
            required.discard("Database")
        if not p.get("BypassGroupManagerCheck", True):
            required.discard("BypassSecurityGroupManagerCheck")
        missing.extend(command + ":" + param for param in sorted(required) if not session.supports(command, param))
    if missing:
        raise Failure(error_type="MissingRBACParameters", data={"missing_parameters": missing})
    # Read only; no New-Mailbox/-WhatIf and no group modifications.
    operations.call("Get-DistributionGroup", RecipientTypeDetails="MailUniversalDistributionGroup", ResultSize=1)
    return {"endpoint": "Microsoft.Exchange", "delegation": False, "commands_checked": sorted(COMMANDS),
            "read_query": "passed", "write_scope_verified": False,
            "note": "Metadata/read checks do not prove OU, database or membership write permissions; isolated business acceptance is still required."}


def execute(request, session_factory=Session):
    session, operations = None, None
    try:
        operation, parameters = request["operation"], request.get("parameters", {})
        if operation not in NEEDED and operation != "check_connection":
            raise Failure("INVALID_REQUEST")
        if not isinstance(parameters, dict):
            raise Failure("INVALID_REQUEST")
        session = session_factory(request["connection"])
        operations = Operations(session, parameters)
        session.open()
        session.inspect(set(COMMANDS) if operation == "check_connection" else NEEDED[operation])
        if operation == "check_connection":
            data = check_connection(operations)
        elif operation in ("ensure_group_member", "remove_group_member"):
            data = operations.membership(remove=operation == "remove_group_member")
        else:
            data = getattr(operations, operation)()
        return {"ok": True, "data": data}
    except Exception as error:
        code = error.code if isinstance(error, Failure) else "EXCHANGE_COMMAND_FAILED"
        category = error.error_type if isinstance(error, Failure) else type(error).__name__
        category = category if re.fullmatch(r"[A-Za-z0-9_.]{1,128}", category or "") else "RemoteCommandError"
        return {"ok": False, "code": code, "message": MESSAGES[code], "error_type": category,
                "state_unknown": bool(operations and operations.mutation_started),
                "data": error.data if isinstance(error, Failure) else None}
    finally:
        if session is not None:
            try:
                session.close()
            except Exception:
                # A teardown error does not invalidate an already verified write.
                # Session quotas should be monitored operationally.
                pass


def main():
    logging.disable(logging.CRITICAL)  # PSRP wire logs may include secrets/recipient data.
    try:
        check = sys.argv[1:] == ["--check"]
        if check:
            bypass = os.environ.get("EXCHANGE_BYPASS_GROUP_MANAGER_CHECK", "true")
            if bypass not in ("1", "t", "T", "TRUE", "true", "True", "0", "f", "F", "FALSE", "false", "False"):
                raise Failure("INVALID_REQUEST")
            request = {"connection": connection_from_env(), "operation": "check_connection", "parameters": {
                "DomainController": os.environ.get("EXCHANGE_DOMAIN_CONTROLLER", ""),
                "OrganizationalUnit": os.environ.get("EXCHANGE_ORGANIZATIONAL_UNIT", ""),
                "MailboxDatabase": os.environ.get("EXCHANGE_MAILBOX_DATABASE", ""),
                "BypassGroupManagerCheck": bypass in ("1", "t", "T", "TRUE", "true", "True"),
            }}
        elif sys.argv[1:]:
            raise Failure("INVALID_REQUEST")
        else:
            raw = sys.stdin.buffer.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise Failure("INVALID_REQUEST")
            request = json.loads(raw)
        result = execute(request)
    except Exception:
        result = {"ok": False, "code": "INVALID_REQUEST", "message": MESSAGES["INVALID_REQUEST"], "state_unknown": False}
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    # The legacy caller expects a structured business failure with successful worker exit.
    return 1 if sys.argv[1:] == ["--check"] and not result["ok"] else 0


if __name__ == "__main__":
    sys.exit(main())
