"""Install the local API under a domain service account without CLI passwords."""

import getpass
import json
from pathlib import Path

import win32service
import win32serviceutil

from .core import configured
from .windows_service import CONFIG_PATH


def main():
    config, _ = configured(json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig")))
    project = Path(config["project_directory"]).resolve()
    if not (project / "automation" / "local" / "Invoke-ExchangeOperation.ps1").is_file():
        raise SystemExit("Project directory does not contain the local PowerShell bridge")
    username = input("服务账号（AD域\\账号）: ").strip()
    if "\\" not in username or not username.split("\\", 1)[1]:
        raise SystemExit("Use AD域\\账号 for the service identity")
    password = getpass.getpass("服务账号密码: ")
    if not password:
        raise SystemExit("Password is required")
    win32serviceutil.InstallService(
        "exchange_local.windows_service.ExchangeAutomationService",
        "ExchangeAutomation", "Exchange Automation API",
        startType=win32service.SERVICE_AUTO_START,
        userName=username, password=password,
        description="Local Python API for Exchange employee mailbox automation",
    )
    print("服务已安装。确认状态目录权限后执行 Start-Service ExchangeAutomation。")


if __name__ == "__main__":
    main()
