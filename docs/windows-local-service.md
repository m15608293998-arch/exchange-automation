# Exchange 本机 Python 服务

Python API 与 Exchange 部署在同一台服务器；本机 Windows PowerShell 5.1 使用 Windows 服务身份连接本机 Exchange 端点。业务调用方只访问 HTTP API，不远程登录 Exchange。

## 1. 手动准备环境

本项目不提供环境一键安装器，也不会自动下载 Python、安装依赖、修改系统权限或防火墙。部署人员手动准备：

- Windows PowerShell 5.1、64 位全机 Python（本次测试使用 3.13.15）。
- 同一个 Python 中安装 `pywin32==312`、`waitress==3.0.2`、本项目 `exchange-automation-local==0.2.0`。
- 仓库位于固定目录，例如 `C:\ExchangeAutomation`；Python 不要安装在管理员的个人用户目录。
- 使用管理员 [建号脚本](../deployment/Initialize-ExchangeAutomation.ps1) 创建的专用 AD 服务账号，手动赋予“作为服务登录”。不需要该账号有邮箱、管理员或远程桌面权限。若域策略存在“拒绝作为服务登录”，交由管理员处理，程序不会覆盖域策略。
- 代码、Python 安装目录、配置文件：管理员/SYSTEM 可写，服务账号只读和执行；普通用户不能修改。状态目录：仅管理员/SYSTEM 和服务账号可写。

内网完全离线，事先带入安装包和匹配 Python/Windows x64 的 wheel。下列是手动准备命令参考，不是业务服务的安装逻辑。

在可联网的 Windows x64 构建机、仓库根目录：

```powershell
py -3.13 -m pip install --upgrade pip setuptools wheel
py -3.13 -m pip wheel --no-deps --no-build-isolation --wheel-dir wheelhouse .
py -3.13 -m pip download --only-binary=:all: --dest wheelhouse pywin32==312 waitress==3.0.2
```

内网管理员手动安装 Python 后，从本地 wheel 安装依赖和应用：

```powershell
py -3.13 -m pip --isolated --disable-pip-version-check install --no-index --find-links=C:\ExchangeAutomation\wheelhouse exchange-automation-local==0.2.0
```

如果未安装 Python 启动器，把 `py -3.13` 换成 Python 的绝对路径，例如 `& 'C:\Program Files\ExchangeAutomationPython\python.exe'`。服务使用同一解释器的 `PythonService.exe`。

服务账号权限由管理员手动设置：在“本地安全策略 → 本地策略 → 用户权限分配 → 作为服务登录”加入该账号；域控或域 GPO 控制此项时由域管理员在对应策略配置。文件夹权限用资源管理器“属性 → 安全 → 高级”设置：代码/Python/配置只读和执行，`state` 目录修改，保留 SYSTEM 和 Administrators 完全控制。不需要本地管理员或远程桌面权限。

## 2. 业务配置

将 [配置模板](../deployment/config.example.json) 复制为 `C:\ProgramData\ExchangeAutomation\config.json`。模板中的生产值为：

| 配置 | 生产值/说明 |
|---|---|
| `mail_domain`、`upn_suffix` | `bjwgby.com`，新员工邮箱/登录后缀，不是服务账号邮箱 |
| `mailbox_database` | `Mailbox Database 1119980504`，无运行时选择提示 |
| `domain_controller` | `EXCHANGE.BJWGBY.COM` |
| `project_directory` | 实际仓库目录，需要包含 `automation\local` 和 `automation\scripts` |
| `state_directory` | 持久状态和日志目录，示例 `C:\ProgramData\ExchangeAutomation\state` |
| `http_address` | 示例 `0.0.0.0:18082`，按实际空闲端口修改 |

测试环境使用其自己的数据库和域控，不要把测试配置覆盖进生产模板。本机 Exchange 地址由本机 FQDN 获取，不再配置远程 Exchange 地址或 AD 密码。

手动准备配置（首次部署，已有配置不要覆盖）：

```powershell
New-Item -ItemType Directory -Path 'C:\ProgramData\ExchangeAutomation\state' -Force | Out-Null
Copy-Item 'C:\ExchangeAutomation\deployment\config.example.json' 'C:\ProgramData\ExchangeAutomation\config.json'
notepad 'C:\ProgramData\ExchangeAutomation\config.json'
```

带入内网主要核对 `project_directory`、`state_directory`、`http_address`；生产数据库、邮箱后缀和 DC 已按截图预填。管理员提供的新账号/密码只在注册服务时输入，不写到 JSON。

`api_token` 保持为空，Postman 使用 No Auth。生产请求鉴权交由接入层对接 Keycloak；接入时应确保业务请求经过该层。本服务不会自动新增 JWT/Bearer 要求，也不会调整 WinRM 或防火墙。只有部署人员主动配置 `api_token` 时，已有的可选 Bearer 校验才启用。

若外部访问超时而本机 `/healthz` 正常，由管理员按批准的网关/调用方 IP 放行所选 TCP 端口，不关闭整个防火墙。Keycloak 网关应负责身份及业务权限校验，并配置 TLS 和请求超时；业务端口限制到受信调用方，避免绕过接入层。默认业务超时 300 秒，网关读取超时应略长于它；超时不能直接认定未执行或盲目重试。

## 3. 注册和运行服务

完成上述手动环境准备后，在管理员 PowerShell 执行：

```powershell
py -3.13 -m exchange_local.install_service
Start-Service ExchangeAutomation
Get-Service ExchangeAutomation
```

注册入口只询问 `AD域\账号` 或 `账号@AD域`、密码，注册 Windows 服务；不负责安装环境或授权。密码由 Windows SCM 保管，不写入配置、日志或命令行。服务以该受限 AD 账号运行，业务权限仍由 Exchange RBAC 控制。

HTTP 使用固定线程数的 Waitress；默认最多同时运行 2 个员工操作，同一员工并发返回 409。停止服务先拒绝新业务，再等待正在执行的操作完成（受 `operation_timeout_seconds` 限制），最后释放单实例锁。管理员升级前先 `Stop-Service`，确认已停止，再更新应用 wheel 和 PowerShell 脚本。

修改源码后，已安装的 Python wheel 不会自动更新。升级时保留 `config.json` 和整个 `state` 目录，停服后带入新 wheel 和匹配的 `automation` 脚本，手动 `pip install --no-index --find-links=… --force-reinstall exchange-automation-local==<版本>`，再启动；不要重复注册同名服务。出现启动问题，查看 Windows“事件查看器 → 应用程序”和 `state\service.log`，优先核对服务登录权、密码、全机 Python 路径及目录读写权限。

离职查询需要 `Get-DistributionGroup -Filter` 只读参数。新版建号脚本会检查它。原脚本创建的查询角色保留父角色参数，通常已具备；若人为裁剪过角色，需管理员检查并仅补上此查询参数，不扩大写权限。

## 4. 验收和结果核查

`GET /healthz` 只检查 HTTP 进程存活，不表示 Exchange 权限验证已通过。业务验收应选取事先不存在的隔离员工：

```http
POST /api/exchange/users
Content-Type: application/json

{"login_name":"testemployee","display_name":"测试员工","initial_password":"<新员工密码>","groups":["app","dev"]}
```

```http
POST /api/exchange/users/testemployee/offboard
```

离职不带请求体，只移除普通通讯组直接成员关系，不禁用账号、不删除邮箱。组名支持唯一短名称，不要求拼接邮件后缀。重复调用应保持幂等。

日志位于 `state_directory\service.log`，包含时间、请求 ID、动作、账号、结果/已完成部分及错误类型，不记录密码和完整请求体。每次操作前刷盘 `account-<login>.pending`；超时且写入结果未知时保留此文件并阻止盲目重试，也识别旧版 `<login>.pending`。根据日志和 Exchange 实际状态核查，停止服务后单独移走已核实的记录留作审计，再启动重试。不要清空整个状态目录。强制杀进程/系统断电不等同于正常停止，必须按此流程核查。

本地模拟回归：

```powershell
py -3.13 -m unittest discover -s tests\python -v
```

模拟测试不代替真实 Exchange 验证，更不能保证所有生产域策略、ACL、独占范围都兼容；上线前仍应用生产服务账号做隔离验收。
