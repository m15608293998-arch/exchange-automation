"""Offline regression: no Exchange credentials or network needed."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("exchange_psrp", Path(__file__).resolve().parents[1] / "direct/exchange_psrp.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

USER = "14b83852-3f81-4667-9017-e0a4d3564f88"
GROUP = "10c11147-b90f-45d1-9d68-4d9fcdecc112"
OTHER = "92ea61da-68ce-4538-8c1e-33f28f54e4df"
PARAMS = dict(LoginName="tester", DisplayName="测试 {{ 7 * 7 }}", UserPrincipalName="tester@example.com",
              PrimarySmtpAddress="tester@example.com", InitialPassword="{{7*7}};$x", DomainController="dc.example.com",
              OrganizationalUnit="OU=Employees,DC=example,DC=com", MailboxDatabase="DB01")


def record(reason):
    return SimpleNamespace(reason=reason, fq_error=reason)


class FakeSession(m.Session):
    def __init__(self):
        self.capabilities = {k: set(v) for k, v in m.COMMANDS.items()}
        self.mailbox = None
        self.collision = False
        self.groups = {GROUP: dict(Guid=GROUP, Name="dev", PrimarySmtpAddress="dev@example.com", RecipientTypeDetails="MailUniversalDistributionGroup")}
        self.members = {GROUP: set()}
        self.calls, self.faults = [], {}
        self.closed = False

    def open(self):
        pass

    def close(self):
        self.closed = True

    def inspect(self, names):
        pass

    def secure_string(self, text):
        return ("SecureString", text)

    def invoke(self, command, p):
        self.calls.append((command, p))
        if command in self.faults:
            return self.faults[command](p)
        identity = p.get("Identity")
        if command == "Get-Mailbox":
            return [self.mailbox] if self.mailbox is not None else []
        if command in ("Get-Recipient", "Get-User"):
            return [{}] if self.collision else []
        if command == "New-Mailbox":
            self.mailbox = dict(Guid=USER, RecipientTypeDetails="UserMailbox", **{
                key: p[key] for key in ("SamAccountName", "UserPrincipalName", "PrimarySmtpAddress", "DisplayName")})
            return [self.mailbox]
        if command == "Get-DistributionGroup":
            if identity is None:
                return list(self.groups.values())
            return [g for g in self.groups.values() if identity in (g["Guid"], g["PrimarySmtpAddress"], g["Name"])]
        if command == "Get-DistributionGroupMember":
            return [{"Guid": member} for member in self.members[identity]]
        if command == "Add-DistributionGroupMember":
            self.members[identity].add(p["Member"])
        elif command == "Remove-DistributionGroupMember":
            self.members[identity].discard(p["Member"])
        else:
            raise AssertionError(command)
        return []


class BusinessTests(unittest.TestCase):
    def setUp(self):
        self.session = FakeSession()

    def run_operation(self, operation, parameters=None):
        return m.execute({"connection": {}, "operation": operation, "parameters": parameters or PARAMS.copy()}, lambda _: self.session)

    def created(self):
        result = self.run_operation("ensure_mailbox")
        self.assertTrue(result["ok"], result)
        return result

    def member_params(self):
        return dict(GroupIdentity=GROUP, MemberIdentity=USER, DomainController="dc.example.com", BypassGroupManagerCheck=True)

    def test_create_retry_literal_password_and_name(self):
        result = self.created()
        self.assertTrue(result["data"]["created"])
        create_params = next(p for cmd, p in self.session.calls if cmd == "New-Mailbox")
        self.assertEqual(create_params["Password"], ("SecureString", PARAMS["InitialPassword"]))
        self.assertEqual(result["data"]["display_name"], PARAMS["DisplayName"])
        self.assertEqual(create_params["Database"], "DB01")
        retry = self.run_operation("ensure_mailbox", dict(PARAMS, InitialPassword=""))
        self.assertTrue(retry["ok"])
        self.assertFalse(retry["data"]["created"])
        self.assertEqual(sum(c == "New-Mailbox" for c, _ in self.session.calls), 1)
        self.assertTrue(self.session.closed)

    def test_missing_initial_password_before_mutation(self):
        result = self.run_operation("ensure_mailbox", dict(PARAMS, InitialPassword=""))
        self.assertEqual(result["code"], "INVALID_REQUEST")
        self.assertFalse(result["state_unknown"])

    def test_empty_ou_uses_exchange_default_without_parameter(self):
        result = self.run_operation("ensure_mailbox", dict(PARAMS, OrganizationalUnit=""))
        self.assertTrue(result["ok"], result)
        parameters = next(p for command, p in self.session.calls if command == "New-Mailbox")
        self.assertNotIn("OrganizationalUnit", parameters)
        self.assertEqual(parameters["Database"], "DB01")

    def test_check_without_ou_does_not_require_ou_parameter(self):
        self.session.capabilities["New-Mailbox"].remove("OrganizationalUnit")
        result = self.run_operation("check_connection", dict(PARAMS, OrganizationalUnit=""))
        self.assertTrue(result["ok"], result)

    def test_ad_collision_does_not_enable_mailbox(self):
        self.session.collision = True
        result = self.run_operation("ensure_mailbox")
        self.assertEqual(result["code"], "RECIPIENT_CONFLICT")
        self.assertFalse(result["state_unknown"])
        self.assertFalse(any(cmd in m.WRITES for cmd, _ in self.session.calls))

    def test_existing_mailbox_checks_each_identity_field(self):
        self.created()
        for field, wrong in (("SamAccountName", "other"), ("UserPrincipalName", "other@example.com"),
                             ("PrimarySmtpAddress", "other@example.com"), ("DisplayName", "other"), ("RecipientTypeDetails", "SharedMailbox")):
            with self.subTest(field=field):
                old = self.session.mailbox[field]
                self.session.mailbox[field] = wrong
                result = self.run_operation("ensure_mailbox")
                self.assertEqual(result["code"], "RECIPIENT_CONFLICT")
                self.assertFalse(result["state_unknown"])
                self.session.mailbox[field] = old

    def test_get_recipient_without_domain_controller(self):
        self.session.capabilities["Get-Recipient"].remove("DomainController")
        self.created()
        for command, p in self.session.calls:
            self.assertEqual("DomainController" in p, command != "Get-Recipient")

    def test_missing_write_parameter_fails_before_create(self):
        self.session.capabilities["New-Mailbox"].remove("Database")
        result = self.run_operation("ensure_mailbox")
        self.assertEqual(result["error_type"], "MissingRBACParameters")
        self.assertFalse(result["state_unknown"])
        self.assertIsNone(self.session.mailbox)

    def test_denied_lookup_is_not_absence(self):
        def denied(_):
            raise m.RemoteFailure([record("PermissionDeniedException")])
        self.session.faults["Get-Mailbox"] = denied
        result = self.run_operation("ensure_mailbox")
        self.assertFalse(result["ok"])
        self.assertFalse(result["state_unknown"])
        self.assertIsNone(self.session.mailbox)

    def test_explicit_not_found_is_absence(self):
        def absent(_):
            if self.session.mailbox:
                return [self.session.mailbox]
            raise m.RemoteFailure([record("ManagementObjectNotFoundException")])
        self.session.faults["Get-Mailbox"] = absent
        self.created()

    def test_mixed_error_records_not_absence(self):
        self.assertFalse(m.RemoteFailure([record("ManagementObjectNotFoundException"), record("AccessDeniedException")]).is_absent())
        self.assertFalse(m.RemoteFailure([]).is_absent())

    def test_write_transport_failure_is_unknown_and_redacted(self):
        def disconnected(_):
            raise RuntimeError("password=DO_NOT_PRINT_ME")
        self.session.faults["New-Mailbox"] = disconnected
        result = self.run_operation("ensure_mailbox")
        self.assertFalse(result["ok"])
        self.assertTrue(result["state_unknown"])
        self.assertNotIn("DO_NOT_PRINT_ME", json.dumps(result))

    def test_failed_readback_is_unknown(self):
        def readback(_):
            if self.session.mailbox:
                raise RuntimeError("readback failure")
            return []
        self.session.faults["Get-Mailbox"] = readback
        result = self.run_operation("ensure_mailbox")
        self.assertTrue(result["state_unknown"])
        self.assertIsNotNone(self.session.mailbox)

    def test_group_resolve_dedup(self):
        result = self.run_operation("resolve_groups", {"GroupIdentities": [GROUP, "dev@example.com", "dev"]})
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["data"]["groups"]), 1)

    def test_missing_group_preflight(self):
        result = self.run_operation("resolve_groups", {"GroupIdentities": ["missing"]})
        self.assertEqual(result["code"], "GROUP_NOT_FOUND")
        self.assertFalse(result["state_unknown"])
        self.assertIsNone(self.session.mailbox)

    def test_security_group_rejected_for_resolve_and_remove(self):
        self.created()
        self.session.groups[GROUP]["RecipientTypeDetails"] = "MailUniversalSecurityGroup"
        for operation, params in (("resolve_groups", {"GroupIdentities": [GROUP]}), ("remove_group_member", self.member_params())):
            result = self.run_operation(operation, params)
            self.assertEqual(result["code"], "GROUP_TYPE_NOT_ALLOWED")
            self.assertFalse(result["state_unknown"])

    def test_add_discover_remove_retry_keeps_mailbox(self):
        self.created()
        first = self.run_operation("ensure_group_member", self.member_params())
        self.assertTrue(first["data"]["added"])
        again = self.run_operation("ensure_group_member", self.member_params())
        self.assertFalse(again["data"]["added"])
        found = self.run_operation("discover_user_groups")
        self.assertEqual(found["data"]["mailbox_id"], USER)
        self.assertEqual(found["data"]["groups"][0]["identity"], GROUP)
        first = self.run_operation("remove_group_member", self.member_params())
        self.assertTrue(first["data"]["removed"])
        again = self.run_operation("remove_group_member", self.member_params())
        self.assertFalse(again["data"]["removed"])
        self.assertIsNotNone(self.session.mailbox)

    def test_wrong_guid_cannot_modify_membership(self):
        self.created()
        result = self.run_operation("ensure_group_member", dict(self.member_params(), MemberIdentity=OTHER))
        self.assertEqual(result["code"], "RECIPIENT_CONFLICT")
        self.assertFalse(result["state_unknown"])

    def test_missing_group_remove_is_idempotent(self):
        self.created()
        result = self.run_operation("remove_group_member", dict(self.member_params(), GroupIdentity=OTHER))
        self.assertTrue(result["ok"])
        self.assertFalse(result["data"]["removed"])

    def test_membership_no_change_after_success_is_not_success(self):
        self.created()
        self.session.faults["Add-DistributionGroupMember"] = lambda _: []
        result = self.run_operation("ensure_group_member", self.member_params())
        self.assertFalse(result["ok"])
        self.assertTrue(result["state_unknown"])

    def test_concurrent_add_confirmed_by_readback(self):
        self.created()
        def external_change(_):
            self.session.members[GROUP].add(USER)
            raise m.RemoteFailure([record("MemberAlreadyExistsException")])
        self.session.faults["Add-DistributionGroupMember"] = external_change
        result = self.run_operation("ensure_group_member", self.member_params())
        self.assertTrue(result["ok"])
        self.assertFalse(result["data"]["added"])

    def test_check_only_reads_and_does_not_claim_write_scope(self):
        result = self.run_operation("check_connection")
        self.assertTrue(result["ok"])
        self.assertFalse(result["data"]["write_scope_verified"])
        self.assertFalse(any(cmd in m.WRITES for cmd, _ in self.session.calls))

    def test_check_lists_missing_parameters_without_writes(self):
        self.session.capabilities["New-Mailbox"].remove("Password")
        result = self.run_operation("check_connection")
        self.assertFalse(result["ok"])
        self.assertIn("New-Mailbox:Password", result["data"]["missing_parameters"])
        self.assertFalse(result["state_unknown"])

    def test_unknown_operation_never_opens_session(self):
        result = self.run_operation("Remove-Mailbox")
        self.assertEqual(result["code"], "INVALID_REQUEST")
        self.assertEqual(self.session.calls, [])


class ConnectionTests(unittest.TestCase):
    def config(self, **kwargs):
        return dict(url="http://exchange.example.com/PowerShell/", auth="kerberos", username="svc@example.com", password="test-only", **kwargs)

    def test_no_delegation_no_proxy_no_retries_encrypted_http(self):
        options = m.connection_options(self.config())
        self.assertEqual(options["port"], 80)
        self.assertEqual(options["path"], "PowerShell/")
        self.assertFalse(options["negotiate_delegate"])
        self.assertTrue(options["no_proxy"])
        self.assertTrue(options["cert_validation"])
        self.assertEqual(options["encryption"], "always")
        self.assertEqual(options["reconnection_retries"], 0)

    def test_kerberos_upn_realm_accepts_lower_upper_and_mixed_case(self):
        for realm in ("example.com", "EXAMPLE.COM", "ExAmPlE.CoM"):
            with self.subTest(realm=realm):
                config = dict(self.config(), username="Svc_Exchange@" + realm)
                original = config.copy()
                options = m.connection_options(config)
                self.assertEqual(options["username"], "Svc_Exchange@EXAMPLE.COM")
                self.assertEqual(options["auth"], "kerberos")
                self.assertEqual(options["reconnection_retries"], 0)
                self.assertEqual(config, original)

    def test_kerberos_normalization_does_not_modify_password(self):
        secret = "  MiXeD-Password!中文@domain  "
        options = m.connection_options(dict(self.config(), username="Svc@example.com", password=secret))
        self.assertEqual(options["username"], "Svc@EXAMPLE.COM")
        self.assertEqual(options["password"], secret)

    def test_kerberos_does_not_guess_realm_for_other_username_forms(self):
        for username in ("Svc", r"Example\Svc", r"Example\Svc@example.com",
                         r"Svc\@Name@example.com", "Svc@@example.com", "@example.com", "Svc@"):
            with self.subTest(username=username):
                self.assertEqual(m.connection_options(dict(self.config(), username=username))["username"], username)

    def test_ntlm_username_is_not_normalized(self):
        for username in ("Svc@ExAmPlE.com", r"Example\Svc"):
            with self.subTest(username=username):
                config = dict(self.config(), auth="ntlm", url="https://exchange.example.com/PowerShell/", username=username)
                self.assertEqual(m.connection_options(config)["username"], username)

    def test_environment_credentials_use_same_kerberos_normalization(self):
        environment = {"EXCHANGE_POWERSHELL_URL": "http://exchange.example.com/PowerShell/",
                       "EXCHANGE_AUTH": "kerberos", "EXCHANGE_USERNAME": "Svc@ExAmPlE.com",
                       "EXCHANGE_PASSWORD": "MiXeD-test-only"}
        with patch.dict(os.environ, environment, clear=True):
            options = m.connection_options(m.connection_from_env())
            self.assertEqual(options["username"], "Svc@EXAMPLE.COM")
            self.assertEqual(options["password"], environment["EXCHANGE_PASSWORD"])
            self.assertEqual(os.environ["EXCHANGE_USERNAME"], "Svc@ExAmPlE.com")

    def test_normalization_is_idempotent(self):
        original = "Svc@ExAmPlE.com"
        once = m.normalize_ad_kerberos_username(original)
        self.assertEqual(m.normalize_ad_kerberos_username(once), once)

    def test_auth_and_endpoint_policy(self):
        for url in ("http://192.0.2.1/PowerShell/", "http://exchange/wsman", "http://x:y@exchange.example.com/PowerShell/", "http://exchange.example.com/PowerShell/?a=1"):
            with self.assertRaises(m.Failure):
                m.connection_options(dict(self.config(), url=url))
        for auth in ("ntlm", "basic", "credssp", "negotiate"):
            with self.assertRaises(m.Failure):
                m.connection_options(dict(self.config(), auth=auth))
        options = m.connection_options(dict(self.config(), auth="ntlm", url="https://exchange.example.com/PowerShell/"))
        self.assertTrue(options["cert_validation"])
        self.assertEqual(options["port"], 443)

    def test_private_credential_file_symlink_and_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "credentials.json"
            path.write_text(json.dumps({"username": "svc@example.com", "password": "test-only"}))
            path.chmod(0o600)
            config = dict(self.config(), username="", password="", credential_file=str(path))
            original = path.read_bytes()
            self.assertEqual(m.connection_options(config)["username"], "svc@EXAMPLE.COM")
            self.assertEqual(path.read_bytes(), original)
            path.chmod(0o644)
            with self.assertRaises(m.Failure):
                m.connection_options(config)
            path.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                m.connection_options(dict(config, credential_file=str(link)))

    def test_deserialized_properties(self):
        obj = SimpleNamespace(adapted_properties={"GUID": USER}, extended_properties={"PrimarySmtpAddress": "dev@example.com"})
        self.assertEqual(m.value(obj, "Guid"), USER)
        self.assertEqual(m.value(obj, "PrimarySmtpAddress"), "dev@example.com")


class RealPSRPSerializationTests(unittest.TestCase):
    def setUp(self):
        try:
            from pypsrp.serializer import Serializer
        except ImportError:
            self.skipTest("pypsrp not installed; install requirements-direct.txt to run protocol tests")

    def test_cmdlet_typed_arguments_never_become_script(self):
        from pypsrp.complex_objects import PSInvocationState
        from pypsrp.powershell import PowerShell
        captured = []
        def invoke(ps):
            captured.extend(ps.commands)
            ps.state = PSInvocationState.COMPLETED
            return []
        session = m.Session(dict(url="http://exchange.example.com/PowerShell/", auth="kerberos", username="test", password="test"))
        session.pool.protocol_version = "2.3"  # Normally negotiated by open(). No network in this test.
        with patch.object(PowerShell, "invoke", invoke):
            session.invoke("Get-Mailbox", {"Identity": "{{7*7}};$(whoami)"})
        self.assertEqual(len(captured), 1)
        self.assertFalse(captured[0].is_script)
        self.assertEqual(captured[0].args[0].value, "{{7*7}};$(whoami)")
        with self.assertRaises(m.Failure):
            session.invoke("Remove-Mailbox", {"Identity": "test"})

    def test_secure_string_real_serializer_encrypts_and_roundtrips(self):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from pypsrp.serializer import Serializer, TaggedValue
        serializer = Serializer()
        serializer.cipher = Cipher(algorithms.AES(b"0" * 32), modes.CBC(b"0" * 16))
        secret = "literal{{7*7}};中文!"
        encoded = serializer.serialize(TaggedValue("SS", secret))
        self.assertEqual(encoded.tag, "SS")
        self.assertNotIn(secret, encoded.text)
        self.assertEqual(serializer.deserialize(encoded), secret)


if __name__ == "__main__":
    unittest.main()
