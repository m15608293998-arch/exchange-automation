"""Windows Service Control Manager entry point (requires pywin32)."""

import json
import logging
import msvcrt
import os
import threading
from logging.handlers import RotatingFileHandler
from pathlib import Path

import win32service
import win32serviceutil

from .api import create_server, RESPONSE_DRAIN_SECONDS
from .core import ExchangeService, PowerShellRunner, configured, MAX_OPERATION_TIMEOUT


CONFIG_PATH = Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "ExchangeAutomation" / "config.json"
# Per-service budget, not the machine-wide WaitToKillServiceTimeout. SCM only
# waits while this service is actually stopping; an idle service stops promptly.
PRESHUTDOWN_MILLISECONDS = (MAX_OPERATION_TIMEOUT + RESPONSE_DRAIN_SECONDS + 30) * 1000


def check_shutdown_budget(config):
    manager = win32service.OpenSCManager(None, None, win32service.SC_MANAGER_CONNECT)
    try:
        service = win32service.OpenService(manager, "ExchangeAutomation", win32service.SERVICE_QUERY_CONFIG)
        try:
            budget = win32service.QueryServiceConfig2(service, win32service.SERVICE_CONFIG_PRESHUTDOWN_INFO)
        finally:
            win32service.CloseServiceHandle(service)
    finally:
        win32service.CloseServiceHandle(manager)
    if budget < (config.get("operation_timeout_seconds", 300) + RESPONSE_DRAIN_SECONDS + 30) * 1000:
        raise ValueError("Service shutdown budget is insufficient; run exchange_local.install_service --configure-shutdown as administrator")


def build_server():
    config, address = configured(json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig")))
    check_shutdown_budget(config)
    state = Path(config["state_directory"])
    state.mkdir(parents=True, exist_ok=True)
    instance_lock = open(state / "service.lock", "a+b")
    try:
        if instance_lock.tell() == 0:
            instance_lock.write(b"0")
            instance_lock.flush()
        instance_lock.seek(0)
        msvcrt.locking(instance_lock.fileno(), msvcrt.LK_NBLCK, 1)
        logger = logging.getLogger("exchange_automation")
        logger.setLevel(logging.INFO)
        handler = RotatingFileHandler(state / "service.log", maxBytes=5 * 1024 * 1024,
                                      backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        logger.addHandler(handler)
        runner = PowerShellRunner(Path(config["project_directory"]) / "automation" / "local" / "Invoke-ExchangeOperation.ps1")
        exchange = ExchangeService(config, runner)
        server = create_server(address, config, exchange, logger)
        server.instance_lock = instance_lock
        return server
    except Exception:
        instance_lock.close()
        raise


class ExchangeAutomationService(win32serviceutil.ServiceFramework):
    _svc_name_ = "ExchangeAutomation"
    _svc_display_name_ = "Exchange Automation API"
    _svc_description_ = "Local Python API for Exchange employee mailbox automation"

    def __init__(self, args):
        super().__init__(args)
        self.server = None
        self.stop_requested = threading.Event()

    def SvcDoRun(self):
        self.server = build_server()
        worker = threading.Thread(target=self.server.serve_forever)
        worker.start()
        try:
            while worker.is_alive() and not self.stop_requested.wait(0.5):
                pass
        finally:
            # SCM callbacks must return quickly. Drain here, reporting progress until all
            # business workers and their bounded PowerShell processes have completed.
            drain = threading.Thread(target=self.server.shutdown)
            drain.start()
            while drain.is_alive():
                self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING, waitHint=15000)
                drain.join(5)
            worker.join()
            self.server.instance_lock.seek(0)
            msvcrt.locking(self.server.instance_lock.fileno(), msvcrt.LK_UNLCK, 1)
            self.server.instance_lock.close()

    def SvcStop(self):
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        if self.server is not None:
            self.server.exchange.begin_stop()
        self.stop_requested.set()

    def GetAcceptedControls(self):
        return super().GetAcceptedControls() | win32service.SERVICE_ACCEPT_PRESHUTDOWN

    def SvcOtherEx(self, control, event_type, data):
        if control == win32service.SERVICE_CONTROL_PRESHUTDOWN:
            self.SvcStop()
        else:
            return super().SvcOtherEx(control, event_type, data)

    def SvcShutdown(self):
        self.SvcStop()
