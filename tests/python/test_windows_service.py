"""Native pywin32 contract tests; SCM calls are mocked, no service is modified."""

import os
import threading
import unittest
from unittest.mock import Mock, patch


@unittest.skipUnless(os.name == "nt", "requires Windows pywin32")
class WindowsServiceTests(unittest.TestCase):
    def setUp(self):
        from exchange_local import windows_service, install_service
        self.runtime, self.installer = windows_service, install_service

    def test_preshutdown_is_accepted_and_rejects_new_business_immediately(self):
        cls = self.runtime.ExchangeAutomationService
        service = cls.__new__(cls)
        service.server = Mock()
        service.stop_requested = threading.Event()
        service.ReportServiceStatus = Mock()
        win32 = self.runtime.win32service
        self.assertTrue(service.GetAcceptedControls() & win32.SERVICE_ACCEPT_PRESHUTDOWN)
        service.SvcOtherEx(win32.SERVICE_CONTROL_PRESHUTDOWN, 0, None)
        self.assertTrue(service.stop_requested.is_set())
        service.server.exchange.begin_stop.assert_called_once_with()
        service.ReportServiceStatus.assert_called_once_with(win32.SERVICE_STOP_PENDING)

    def test_shutdown_budget_configuration_and_readback_use_scoped_permissions(self):
        win32 = self.runtime.win32service
        for fails in (False, True):
            with self.subTest(fails=fails), \
                    patch.object(win32, "OpenSCManager", return_value="manager") as manager, \
                    patch.object(win32, "OpenService", return_value="service") as opened, \
                    patch.object(win32, "CloseServiceHandle") as closed, \
                    patch.object(win32, "ChangeServiceConfig2", side_effect=OSError if fails else None) as change:
                if fails:
                    with self.assertRaises(OSError):
                        self.installer.configure_shutdown()
                else:
                    self.installer.configure_shutdown()
                manager.assert_called_once_with(None, None, win32.SC_MANAGER_CONNECT)
                opened.assert_called_once_with("manager", "ExchangeAutomation", win32.SERVICE_CHANGE_CONFIG)
                change.assert_called_once_with("service", win32.SERVICE_CONFIG_PRESHUTDOWN_INFO,
                                               self.runtime.PRESHUTDOWN_MILLISECONDS)
                self.assertEqual([call.args[0] for call in closed.call_args_list], ["service", "manager"])
        with patch.object(win32, "OpenSCManager", return_value="manager"), \
                patch.object(win32, "OpenService", return_value="service") as opened, \
                patch.object(win32, "CloseServiceHandle"), \
                patch.object(win32, "QueryServiceConfig2", return_value=10000) as query:
            with self.assertRaisesRegex(ValueError, "configure-shutdown"):
                self.runtime.check_shutdown_budget({})
            opened.assert_called_once_with("manager", "ExchangeAutomation", win32.SERVICE_QUERY_CONFIG)
            query.return_value = self.runtime.PRESHUTDOWN_MILLISECONDS
            self.runtime.check_shutdown_budget({"operation_timeout_seconds": 1800})

    def test_shutdown_only_upgrade_does_not_prompt_or_reregister(self):
        with patch("sys.argv", ["install_service", "--configure-shutdown"]), \
                patch.object(self.installer, "configure_shutdown") as configure, \
                patch.object(self.installer, "install") as install, patch("builtins.input") as prompt:
            self.installer.main()
        configure.assert_called_once_with()
        install.assert_not_called()
        prompt.assert_not_called()
