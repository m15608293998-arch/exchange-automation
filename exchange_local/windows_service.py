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

from .api import create_server
from .core import ExchangeService, PowerShellRunner, configured


CONFIG_PATH = Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "ExchangeAutomation" / "config.json"


def build_server():
    config, address = configured(json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig")))
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
        self.stop_requested.set()

    def SvcShutdown(self):
        self.SvcStop()
