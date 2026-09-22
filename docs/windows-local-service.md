# Exchange 本机 Python 服务部署

本方案把 HTTP 服务安装在 Exchange 服务器上。Python 服务以专用 AD 账号运行，启动本机 Windows PowerShell 5.1，PowerShell 连接**本机** `Microsoft.Exchange` 端点并受该账号的 Exchange RBAC 限制。业务调用方只访问 Python HTTP 接口。服务器自身使用的 WinRM/Exchange PowerShell 组件保持正常运行。

现有管理员建号脚本 [Initialize-ExchangeAutomation.ps1](../deployment/Initialize-ExchangeAutomation.ps1) 仍用于创建服务账号和业务 RBAC；它的 `RemotePowerShellEnabled` 是本机标准 Exchange 会话所需。服务账号不需要邮箱、本地管理员或远程桌面权限。另需允许此账号“作为服务登录”，以便 Windows 服务管理器启动它。

## 1. 离线准备

在可联网的 **Windows x64 构建机**准备与内网相同版本的 64 位 Python 安装包和 wheel。建议 Python 3.11。把本仓库复制到内网 Exchange 的固定目录，例如 `C:\ExchangeAutomation`，不要放在服务账号可修改的位置。

在外网构建机先准备新版 `pip`、`setuptools`、`wheel`，然后在仓库根目录生成应用 wheel，并下载对应 Python 版本的 pywin32 wheel：

```powershell
py -3.11 -m pip install --upgrade pip setuptools wheel
py -3.11 -m pip wheel --no-deps --no-build-isolation --wheel-dir wheelhouse .
py -3.11 -m pip download --only-binary=:all: --dest wheelhouse pywin32==312
```

把 `wheelhouse`、仓库代码和 Python 安装包一同交付内网。内网只使用本地 wheel，不访问包索引：

```powershell
py -3.11 -m pip --isolated --disable-pip-version-check install --no-index --find-links=C:\ExchangeAutomation\wheelhouse exchange-automation-local==0.1.0 pywin32==312
```

如果内网 Python 不支持 `py -3.11`，把命令中的 `py -3.11` 换成该 Python 的绝对路径。pywin32 及本项目必须安装到**同一个** 64 位 Python；Windows 服务使用其 `PythonService.exe`。wheel 必须与 Python 版本、Windows 架构匹配。

## 2. 配置

管理员在生产 Exchange 上运行建号脚本，获取 `AD域\账号` 或 `账号@AD域` 和密码。服务安装时使用 `AD域\账号`；密码只在安装提示中输入，不写入配置文件或命令行。把 [Windows 配置模板](../deployment/windows-local-config.json.example) 复制为 `C:\ProgramData\ExchangeAutomation\config.json`。模板已按收到的生产信息填入员工邮箱后缀、域控和数据库；检查 `project_directory`、`http_address`、`state_directory` 与实际部署一致。`project_directory` 指向含 `automation\scripts` 的仓库目录。监听端口示例为 18082，按本机实际空闲端口调整。

```powershell
New-Item -ItemType Directory -Path 'C:\ProgramData\ExchangeAutomation' -Force | Out-Null
Copy-Item 'C:\ExchangeAutomation\deployment\windows-local-config.json.example' 'C:\ProgramData\ExchangeAutomation\config.json'
notepad 'C:\ProgramData\ExchangeAutomation\config.json'
```

`api_token` 留空时，Postman 使用 No Auth，和当前服务一致。若以后主动填入至少 32 字节的 Token，接口才要求 Bearer。配置文件不能存服务账号密码。员工请求的 `groups` 可直接使用唯一的 `app`、`dev` 之类短名称，不需要拼邮箱域。

状态目录必须长期保留，服务账号需要读写权限。新建目录后由管理员给该账号“修改”权限，保留 SYSTEM 和 Administrators 的完全控制，并检查其他普通用户不能改动其中的 `.pending` 文件。安装后不要随意清空目录；它用于识别结果不确定的操作。

## 3. 安装和启动

在**管理员权限**的 Windows PowerShell 中执行：

```powershell
py -3.11 -m exchange_local.install_service
Start-Service ExchangeAutomation
Get-Service ExchangeAutomation
```

安装器仅询问服务账号 `AD域\账号` 和密码，通过 Windows 服务管理器保存服务登录凭据；不会把密码放到命令行。管理员需要确保该账号具有“作为服务登录”权限。如果 `Start-Service` 报登录失败，先检查该权限及密码。服务日志在 `state_directory\service.log`，不记录请求体或密码。

服务运行期间，Python 用固定的本地 `powershell.exe -File` 执行 [桥接脚本](../automation/local/Invoke-ExchangeOperation.ps1)。业务参数从标准输入传入；桥接脚本只允许五个固定操作，并调用已有的 Exchange 业务脚本。服务本身不调用其他机器上的 PowerShell。

## 4. 验收

先在 Exchange 本机执行 `Invoke-WebRequest http://127.0.0.1:18082/healthz`，确认服务运行。`/healthz` 只表示 HTTP 进程存活。然后用 Postman 对事先不存在的隔离测试员工调用入职接口，验证 AD 账号、邮箱和指定普通通讯组；再调用离职接口验证直接成员移除。重复调用入职、离职，检查幂等结果。生产验收应使用真实生产服务账号和经过批准的测试对象。

接口保持：

```http
POST /api/exchange/users
Content-Type: application/json

{"login_name":"testemployee","display_name":"测试员工","initial_password":"<新员工密码>","groups":["app","dev"]}
```

```http
POST /api/exchange/users/testemployee/offboard
```

第二个接口不带请求体，只清理通讯组直接成员关系，不禁用账号或删除邮箱。若响应 `state_unknown=true`，先根据日志和 Exchange 实际状态核实，再处理 `state_directory` 中对应账号的 `.pending` 文件。

本地开发机没有 Exchange/Windows 服务环境时，只能运行模拟回归，不能把模拟结果当作生产实机验收：

```powershell
py -3.11 -m unittest discover -s exchange_local\tests -v
```

目前测试 Exchange 的 Windows PowerShell 5.1 已通过桥接脚本语法和模拟参数绑定测试；该服务器尚无 Python，因此 Windows 服务的安装、启动和真实业务写入仍须在已备好离线 Python 的测试环境验收。
