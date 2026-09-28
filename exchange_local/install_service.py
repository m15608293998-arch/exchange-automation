"""Register the Windows service only; Python, dependencies and permissions are prepared manually."""

import getpass
import argparse
import json
from pathlib import Path

import win32security
import win32service
import win32serviceutil

from .core import configured
from .windows_service import CONFIG_PATH, PRESHUTDOWN_MILLISECONDS


def configure_shutdown():
    # Only this service's SCM setting; no global policy or additional user rights.
    manager = win32service.OpenSCManager(None, None, win32service.SC_MANAGER_CONNECT)
    try:
        service = win32service.OpenService(manager, "ExchangeAutomation", win32service.SERVICE_CHANGE_CONFIG)
        try:
            win32service.ChangeServiceConfig2(service, win32service.SERVICE_CONFIG_PRESHUTDOWN_INFO,
                                             PRESHUTDOWN_MILLISECONDS)
        finally:
            win32service.CloseServiceHandle(service)
    finally:
        win32service.CloseServiceHandle(manager)


def install(username, password):
    # 只检查业务脚本位置；不下载、不安装依赖，也不修改系统或目录权限。
    config, _ = configured(json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig")))
    project = Path(config["project_directory"]).resolve()
    if not (project / "automation" / "local" / "Invoke-ExchangeOperation.ps1").is_file():
        raise ValueError("Project directory does not contain the local PowerShell bridge")
    if not password:
        raise ValueError("Password is required")
    # 兼容管理员建号脚本返回的 UPN，以及 AD域\账号；统一给 SCM 使用。
    sid, _, kind = win32security.LookupAccountName(None, username)
    account, domain, _ = win32security.LookupAccountSid(None, sid)
    if kind != win32security.SidTypeUser:
        raise ValueError("Service identity must be a domain user")
    # 仅注册 Windows 服务。密码交给 SCM 保管，不写入配置或命令行。
    win32serviceutil.InstallService(
        "exchange_local.windows_service.ExchangeAutomationService",
        "ExchangeAutomation", "Exchange Automation API",
        startType=win32service.SERVICE_AUTO_START,
        userName=domain + "\\" + account, password=password,
        description="Local Python API for Exchange employee mailbox automation",
    )
    configure_shutdown()
    print("服务已注册。确认服务登录权及目录权限后执行 Start-Service ExchangeAutomation。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configure-shutdown", action="store_true",
                        help="Update only the existing service's preshutdown budget; no credentials required")
    if parser.parse_args().configure_shutdown:
        configure_shutdown()
        print("已更新本服务的关机前等待时间，未更改账号或系统全局关机策略。")
        return
    install(input("服务账号（AD域\\账号或账号@AD域）: ").strip(), getpass.getpass("服务账号密码: "))


if __name__ == "__main__":
    main()
