# 完全隔离内网：迁移时改哪些地方

本页适用原 Linux `direct` 连接方式。新的 Exchange 本机 Python 服务请使用 [Windows 本机服务部署说明](windows-local-service.md)。**不用改 Go/Python 源码，也不用把测试服务器地址逐个替换进脚本。** Exchange 管理员在生产服务器重新运行建号脚本；应用维护方修改连接、业务和 Linux Kerberos 配置即可。

这里的内网指完全无法访问互联网。管理员脚本不下载组件、不向微软网站发请求；应用依赖提前准备本地离线包，见 [离线交付步骤](../README.md#依赖与离线交付)。不要把测试机的临时 Python 目录当作生产安装包。

## 1. Exchange 管理员做什么

只读采集结果已经收到，生产差异及尚未验证的边界见 [生产环境适配记录](production-environment-2026-09-20.md)。下一步由管理员执行以下建号步骤；不要把只读采集脚本和建号脚本混用。

复制 [Initialize-ExchangeAutomation.ps1](../deployment/Initialize-ExchangeAutomation.ps1)，在生产 Exchange 服务器的 64 位 Windows PowerShell 5.1 或 Exchange Management Shell 中执行：

```powershell
.\Initialize-ExchangeAutomation.ps1
```

只输入新服务账号名称和新密码，不询问员工邮箱后缀、数据库或 OU。管理员需要已有的 AD 建号及 Exchange RBAC 管理权限。成功后交付：

- 返回的 `新账号@生产AD域` 和刚才设置的密码，密码另走安全渠道。
- 自动生成的 `connection.env.example`，用于读取生产 Exchange URL、DC 和登录名；有问题时附上 `setup-report.json`。

脚本自动发现的是**执行脚本的生产服务器所在环境**。不要把测试环境生成的账号、密码、连接报告拿到生产继续使用。脚本内的 `schemas.microsoft.com` 是会话类型标识，不是外网测试地址，也不需要替换。

## 2. 应用维护方改哪些配置

使用仓库的 systemd 服务时，配置文件为 `/etc/exchange-automation.env`，由 [服务文件](../deployment/exchange-automation.service) 的 `EnvironmentFile` 加载。程序**不会自动读取项目根目录的 `.env`**。手动运行时，必须显式提供进程环境变量。

可直接复制 [BJWGBY 生产配置模板](../deployment/bjwgby-production.env.example) 到内网后补齐占位值。下表说明各项来源；生产值已根据只读截图填写到该模板。

| 配置位置/参数 | 应填内容 | 注意事项 |
|---|---|---|
| `EXCHANGE_POWERSHELL_URL` | `http://EXCHANGE.BJWGBY.COM/PowerShell/` | 使用真实服务器 FQDN，不使用 IP；不默认使用 `mail.bjwgby.com` 别名，因为采集结果没有证明该别名的 HTTP SPN |
| `EXCHANGE_DOMAIN_CONTROLLER` | `EXCHANGE.BJWGBY.COM` | 生产采集确认的可写 DC；该服务器同时是 Exchange 和域控 |
| `EXCHANGE_CREDENTIAL_FILE` 指向的 JSON 文件 | 生产服务账号的完整登录名和密码 | 不是管理员凭据；文件权限 0600，所有者为运行程序的 Linux 服务用户 |
| `EXCHANGE_MAIL_DOMAIN` | `bjwgby.com` | 唯一员工邮箱后缀；员工邮箱为 `login_name@bjwgby.com`，建号脚本不询问 |
| `EXCHANGE_UPN_SUFFIX` | `bjwgby.com` | 生产为单一 `BJWGBY.COM` AD 域且无额外 UPN 后缀；若管理员另有员工登录命名规范，业务验收前调整 |
| `EXCHANGE_MAILBOX_DATABASE` | `Mailbox Database 1119980504` | 采集到的唯一数据库，Mounted=true、Recovery=false、未排除预配 |
| `EXCHANGE_ORGANIZATIONAL_UNIT` | 可留空 | 留空使用 Exchange 默认创建位置，不需要为了本项目新建员工 OU |
| `KRB5_CONFIG` 指向的配置文件 | [生产 Kerberos 模板](../deployment/krb5.bjwgby.conf.example) | Realm 为 `BJWGBY.COM`，KDC 为 `EXCHANGE.BJWGBY.COM`；不能使用测试配置 |
| `HTTP_ADDRESS` | 业务程序所在 Linux 机器的监听 IP 和端口，如 `10.20.1.30:8080` | 这是 Postman 调用的服务，不是 Exchange；`127.0.0.1` 只允许本机访问，`0.0.0.0` 监听所有网卡 |
| `EXCHANGE_PYTHON_BINARY` | 内网安装的 Python 虚拟环境绝对路径 | 标准目录为 `/opt/exchange-automation/.venv/bin/python` |
| `EXCHANGE_STATE_DIRECTORY` | 生产独立的持久状态目录 | 标准服务使用 `/var/lib/exchange-automation`，仅服务用户可访问（0700）；不要带入测试状态；已有生产状态不可清空 |

保持 `EXCHANGE_CONNECTION_MODE=direct`、`EXCHANGE_AUTH=kerberos`、`EXCHANGE_BYPASS_GROUP_MANAGER_CHECK=true`。默认直连不读取 `automation/inventory/hosts.yml`，无需再配置旧的 `EXCHANGE_HOST`、`EXCHANGE_WINRM_*` 或 Windows 5985 登录。

凭据文件结构如下；真实密码由安全方式填写，不放到终端命令历史或文档中：

```json
{
  "username": "svc_exchange_app@corp.example.internal",
  "password": "<新服务账号密码>"
}
```

**使用凭据文件时，不要同时设置 `EXCHANGE_USERNAME`、`EXCHANGE_PASSWORD`。** 管理员报告中的 `EXCHANGE_USERNAME` 应填入 JSON 的 `username`，不是把整份 `connection.env.example` 直接覆盖到应用配置。该报告不含密码，也不含员工邮箱和数据库等业务配置。

数据库可以从 UI 或 PowerShell 查看，两种方式任选其一，不需要另建数据库：

- **UI**：用管理员身份打开内网 Exchange 管理中心，进入 **服务器 → 数据库**（英文界面 `servers → databases`），复制列表中的数据库名称。不是服务器名称，也不是 `.edb` 文件路径。此入口适用于当前测试环境对应的 Exchange Server 2019。[界面说明](https://learn.microsoft.com/en-us/exchange/architecture/mailbox-servers/manage-databases)
- **PowerShell**：在 Exchange 服务器上打开 **Exchange Management Shell**，执行以下只读查询。普通 PowerShell 若未加载 Exchange 管理环境，会找不到这个命令。[命令说明](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-mailboxdatabase?view=exchange-ps)

```powershell
Get-MailboxDatabase -Status | Format-Table Name,Server,Mounted -AutoSize
```

`Name` 是要填写的数据库名，`Server` 是所在服务器，`Mounted=True` 表示已挂载；挂载状态本身不等于新员工放置策略或写权限已验收。假设选定的 `Name` 是 `Employees DB`，应用环境配置为：

```ini
EXCHANGE_MAILBOX_DATABASE="Employees DB"
```

如果返回多个数据库，需要确认新员工放到哪个数据库，而不是仅凭数量或排序猜测。本业务服务账号不因此额外获得数据库管理权限。查询只访问内网 Exchange；以上官方链接是说明依据，内网执行不需要打开网页。

## 3. Linux 域认证配置

配置内网 DNS，使生产 Exchange/DC 的 FQDN 解析到正确内网地址；Linux 必须能够访问内网 KDC 并与域时间同步。不需要 Linux 加域，不需要访问公共 DNS、公共 NTP 或互联网。

可以使用应用专用 `/etc/exchange-automation/krb5.conf`，避免覆盖机器上其他应用的 Kerberos 配置，并在进程环境中设置：

```ini
KRB5_CONFIG=/etc/exchange-automation/krb5.conf
```

生产模板已经生成，可复制为 `/etc/exchange-automation/krb5.conf`：

```bash
cp deployment/krb5.bjwgby.conf.example /etc/exchange-automation/krb5.conf
```

Realm 使用实际 AD 域对应的大写形式，不是员工邮箱域。服务账号登录名的域后缀可以保留脚本返回的小写，程序会处理大小写；密码不转换。若已有正常的生产 Kerberos 配置可直接使用，不必另建文件。

## 4. 先做内网只读验证，再做业务验收

下面只验证连接和业务命令，不启动 HTTP 服务，不创建员工，不需要 API Token。替换示例值和安装路径后执行；使用 `env` 仅向这个检查进程提供配置，不会自动读取 systemd 的环境文件：

```bash
env -u EXCHANGE_USERNAME -u EXCHANGE_PASSWORD \
  EXCHANGE_POWERSHELL_URL='http://EXCHANGE.BJWGBY.COM/PowerShell/' \
  EXCHANGE_AUTH=kerberos \
  EXCHANGE_CREDENTIAL_FILE=/etc/exchange-automation/credentials.json \
  EXCHANGE_DOMAIN_CONTROLLER=EXCHANGE.BJWGBY.COM \
  EXCHANGE_MAILBOX_DATABASE='Mailbox Database 1119980504' \
  EXCHANGE_BYPASS_GROUP_MANAGER_CHECK=true \
  KRB5_CONFIG=/etc/exchange-automation/krb5.conf \
  /opt/exchange-automation/.venv/bin/python -B \
  /opt/exchange-automation/automation/direct/exchange_psrp.py --check
```

用实际运行服务的 Linux 用户执行，使其能读取凭据和 Kerberos 配置。返回 `ok=true` 代表登录、命令/参数元数据和读取通过，**不证明数据库可写或所有业务权限已通过**。还需使用事先不存在的隔离员工账号，验证创建 AD+邮箱、加入/移出实际普通测试通讯组；不要拿真实员工做验收。

接口路径和 JSON 字段不因 Exchange 地址变化而改变，Postman 的主机/端口改为业务 Linux 机器的地址。组参数可以继续用内网实际唯一的 `app`、`dev` 等短名称，不必拼测试邮箱后缀。

2026-09-22 已按用户要求取消强制 API Token：`API_TOKEN` 留空即可启动，Postman 使用 No Auth。只有主动配置非空且至少 32 字节的 Token 才启用 Bearer 校验；已有非空 Token 配置不会被忽略。
