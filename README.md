# Exchange 员工邮箱自动化

Go 提供 HTTP API、校验、编排与审计；默认由本地 Python/PSRP **直接连接 Exchange `/PowerShell/` 受限端点**，不再先登录普通 Windows PowerShell，也不需要 Kerberos 委派。生产前提：**调用入职接口前 AD 用户不存在，由 New-Mailbox 同时创建 AD 用户和邮箱**。

管理员可使用 [初始化脚本](deployment/Initialize-ExchangeAutomation.ps1) 创建普通 AD 服务账号及专用业务角色：**组织范围创建普通员工邮箱，维护所有普通静态通讯组的成员，不按员工 OU 或组名单授权**。管理员执行说明见 [一页交付指南](docs/admin-setup.md)；连接说明见 [生产直连交付说明](docs/production-direct.md)。旧 Ansible 双跳实现仅作为显式回退保留。

管理员直接运行初始化脚本，只需输入要新建的账号名和密码；成功返回 `账号@AD域`。脚本不再要求选择邮箱域、数据库或员工 OU，这些员工业务设置保留在应用部署配置中。

搬到完全隔离内网、使用新的 Exchange 地址时，逐项修改位置见 [内网迁移配置清单](docs/intranet-migration.md)。不需要改业务源码，也不需要访问微软网站做测试。

生产只读采集结果已经收到并完成适配，见 [生产环境记录](docs/production-environment-2026-09-20.md)。可使用 [BJWGBY 生产配置模板](deployment/bjwgby-production.env.example) 和 [Kerberos 模板](deployment/krb5.bjwgby.conf.example)；两者均不包含密码。

## 操作边界

- 只创建普通 UserMailbox；AD 用户已存在但没有邮箱时返回冲突，不调用 Enable-Mailbox。
- 只处理普通静态邮件通讯组（MailUniversalDistributionGroup），排除动态组、启用邮件的安全组及普通 AD 安全组。
- 离职接口只清理直接组成员关系，保留 AD 用户、邮箱与地址，不禁用登录，也不代表完整的账号离职流程。
- 仅操作服务账号 RBAC 可见范围；必须在生产验收时核对读取范围与写入范围。不会擅自扩大 RBAC 或修改 Exchange 配置。
- 单实例部署。不同用户默认最多同时执行 2 个请求；同一用户同时入职、离职或重试返回 409。状态目录上的进程锁防止同机重复启动；不支持多控制机分布式部署。

## 入职 API

```http
POST /api/exchange/users
Authorization: Bearer <service-token>
Content-Type: application/json

{
  "login_name": "slpeng",
  "display_name": "江流",
  "initial_password": "<new-account-password>",
  "groups": ["<distribution-group-guid>", "dev@example.com"]
}
```

| 字段 | 约定 |
|---|---|
| login_name | 必填，1–20 位 ASCII，首位字母或数字，其余允许字母、数字、点、下划线、横线；不允许连续点或末尾点；统一小写 |
| display_name | 必填，去除首尾空白，最多 256 个字符，不允许控制字符；已有邮箱显示名不同返回 409，不隐式改名 |
| initial_password | 新建 AD 用户必需；已存在且完全匹配的邮箱重试可省略；永不重置已有密码 |
| groups | 可省略或为空数组，表示不加组；最多 100 项；接受 GUID、SMTP、Alias 或唯一名称，推荐 GUID；语义为追加，不整体替换成员关系 |

服务先解析全部请求组，检查类型并按 GUID 去重，再创建邮箱。预检失败不创建账号。组被外部管理员在预检后修改/删除等情况仍可能导致部分成功。

账号、Alias、Name、FirstName 默认取 login_name。UPN 为 login_name@EXCHANGE_UPN_SUFFIX（未设置时使用邮箱域）；主邮箱为 login_name@EXCHANGE_MAIL_DOMAIN。OU、数据库、DC 是部署配置，不接受调用方任意覆盖。OU 可留空，使用 Exchange 默认创建位置；填写 OU 也只是选择新用户创建位置，不限制维护已有员工的范围。

创建返回 201，已有完全匹配的邮箱返回 200：

```json
{
  "login_name": "slpeng",
  "mailbox_id": "<AD-object-guid>",
  "display_name": "江流",
  "user_principal_name": "slpeng@example.com",
  "primary_smtp_address": "slpeng@example.com",
  "created": true,
  "password_applied": true,
  "added_groups": ["dev@example.com"],
  "existing_groups": []
}
```

重试返回 created=false、password_applied=false，表示本次没有设置密码。已有对象必须匹配账号、UPN、SMTP 地址、显示名和 UserMailbox 类型，否则返回 409。首次失败后再试不能根据“请求带过某个密码”推断当前密码。

## 通讯组离职清理 API

```http
POST /api/exchange/users/slpeng/offboard
Authorization: Bearer <service-token>
```

不接受请求体。先验证账号、UPN 和对象类型，再固定用户 GUID；所有移除操作使用同一 GUID，并复核组 GUID 与类型。

```json
{
  "login_name": "slpeng",
  "mailbox_id": "<AD-object-guid>",
  "removed_groups": ["dev@example.com"]
}
```

重复调用返回空 removed_groups。账号不存在返回 404。清理的是发现时可见的直接成员关系，不遍历嵌套有效成员关系，也不能阻止其他管理系统随后重新加组。

## 失败、超时与恢复

错误响应包括 request_id，与 X-Request-ID 响应头及审计日志对应：

```json
{
  "error": {
    "code": "AUTOMATION_UNAVAILABLE",
    "message": "Automation execution failed; reconcile any uncertain changes",
    "step": "ensure_group_member",
    "target": "<group-guid>",
    "state_unknown": true
  },
  "request_id": "<generated-request-id>",
  "partial_result": {
    "login_name": "slpeng",
    "mailbox_id": "<confirmed-guid>",
    "display_name": "江流",
    "user_principal_name": "slpeng@example.com",
    "primary_smtp_address": "slpeng@example.com",
    "created": true,
    "password_applied": true,
    "added_groups": [],
    "existing_groups": []
  }
}
```

partial_result 只表示已确认的进度；没有它不等于远端没有发生变更。正常的部分成功不回滚，重试会检查已有状态。state_unknown=true 表示远端写入结果不确定，**不可自动重试**。

每次操作开始前，在 EXCHANGE_STATE_DIRECTORY 中创建并同步一个 login_name.pending 文件，不含密码。确定完成或明确失败后删除；执行中断、未知写入结果或进程崩溃时保留。存在该记录的用户后续请求返回 OPERATION_STATE_UNKNOWN；重启不能自动清除记录。

恢复步骤：

1. 根据请求 ID、日志中的用户 GUID、步骤和组 GUID 检查 Exchange 实际状态，并确认旧命令已经结束。
2. 记录核实结果；停止服务后仅移走该用户的 pending 文件，保留作审计。不要批量清空状态目录。
3. 重启服务并重试需要完成的操作。服务进程内也会阻止未知状态用户继续写入。

| 状态码 | 场景 |
|---|---|
| 200 / 201 | 成功 / 新建成功 |
| 400 / 415 | 参数或 JSON 错误 / 非 application/json |
| 401 | 缺失或错误的服务 Bearer token |
| 404 | 目标邮箱不存在 |
| 409 | 身份冲突、同用户操作中、需要人工核实的未知状态 |
| 422 | 组不存在或组类型不允许 |
| 429 | 全局操作并发已满 |
| 502 | 执行或结果协议错误 |
| 504 | 操作超时/中断，结合 state_unknown 判断是否需要核实 |

## 配置与生产部署

程序不会自动读取 .env。生产配置见 [.env.example](.env.example)，由 systemd EnvironmentFile、容器 Secret 或进程环境注入；测试环境独立示例见 [deployment/test.env.example](deployment/test.env.example)。默认 APP_ENV=production。

生产必须明确设置：

- API_TOKEN：至少 32 字节的随机服务令牌；不是 Keycloak 用户 JWT。
- EXCHANGE_POWERSHELL_URL，例如 http://exchange01.corp.example.com/PowerShell/。
- EXCHANGE_CREDENTIAL_FILE：权限 0600 的 JSON 凭据文件（username/password）；或不设文件、改为注入 EXCHANGE_USERNAME 与 EXCHANGE_PASSWORD，不允许混用。
- EXCHANGE_MAIL_DOMAIN、EXCHANGE_MAILBOX_DATABASE、EXCHANGE_DOMAIN_CONTROLLER；EXCHANGE_ORGANIZATIONAL_UNIT 可不填。
- EXCHANGE_STATE_DIRECTORY：持久化的专用本地目录，权限 0700，不同部署不能随意更换目录来绕过待核实记录。

其他配置：

| 变量 | 默认 | 说明 |
|---|---|---|
| HTTP_ADDRESS | 127.0.0.1:8080 | 由本地反向代理对外提供 TLS |
| EXCHANGE_UPN_SUFFIX | 邮箱域 | UPN 后缀，须符合生产 AD 规范 |
| EXCHANGE_ORGANIZATIONAL_UNIT | 空 | 可选创建位置；空值使用 Exchange 默认，不是员工授权范围 |
| EXCHANGE_OPERATION_TIMEOUT | 5m | 含组预检在内的完整业务操作时限 |
| EXCHANGE_MAX_CONCURRENT_OPERATIONS | 2 | 允许 1–16；生产按 Exchange 配额测试 |
| EXCHANGE_RESET_PASSWORD_ON_NEXT_LOGON | false | 创建新账号时应用 |
| EXCHANGE_BYPASS_GROUP_MANAGER_CHECK | true | 需 RBAC 允许 BypassSecurityGroupManagerCheck 参数 |
| EXCHANGE_CONNECTION_MODE | direct | ansible 仅供显式回退，绝不自动降级 |
| EXCHANGE_AUTH | kerberos | 不委派；可选 ntlm 仅允许已支持它的 HTTPS 端点 |
| EXCHANGE_POWERSHELL_URL | 无 | 必须为 FQDN /PowerShell/ URL；http 默认 80，https 默认 443 |
| EXCHANGE_PYTHON_BINARY | python3 | 生产建议专用虚拟环境中的绝对路径 |
| EXCHANGE_DIRECT_WORKER | automation/direct/exchange_psrp.py | 相对工作目录解析 |
| REQUESTS_CA_BUNDLE | requests 默认信任链 | HTTPS 内部 CA 证书链；不支持跳过证书校验 |

直连固定配置：忽略 HTTP 代理、Kerberos SPN 服务名 HTTP、不委派、无传输层自动重试；HTTP 使用 Kerberos 消息加密，HTTPS 使用校验证书的 TLS，SecureString 另由 PSRP 会话密钥加密。连接超时 15 秒，WSMan 单次操作/读取超时 60/70 秒，完整业务超时由 EXCHANGE_OPERATION_TIMEOUT 控制。

只允许可信网关持有服务 token；网关负责 Keycloak 用户认证及操作授权，后端使用服务 token 防止绕过网关直接调用。服务 token 本身不提供员工级权限区分。不要跨不可信网络明文传输 HTTP API 密码/token。

提供 [systemd 示例](deployment/exchange-automation.service)。部署前创建专用低权限 Linux 用户，安装到 /opt/exchange-automation，将权限为 0600 的配置放在 /etc/exchange-automation.env。Python 环境和凭据文件必须对该用户可读，不能依赖 /root 下的安装。示例通过 StateDirectory/RuntimeDirectory 创建 0700 目录；TimeoutStopSec 必须大于业务超时加 20 秒。

## 连接检查与最小权限

普通 AD 域服务账号只需 Exchange RemotePowerShellEnabled 及业务 RBAC，不要求普通 Microsoft.PowerShell 端点访问权、Windows 本地管理员、Domain Admin 或 RDP 权限。Exchange 自身使用的 WinRM 组件仍需正常运行；“不需要开放普通 WinRM 登录”不代表可以停用 Exchange 的底层组件。

应用只执行 New-Mailbox、Get-Mailbox、Get-Recipient、Get-User、Get-DistributionGroup、Get-DistributionGroupMember、Add-DistributionGroupMember、Remove-DistributionGroupMember，并通过 Get-Command 检查参数。不会运行任意远程脚本。完整命令/参数与作用范围要求见 [管理员交付说明](docs/production-direct.md)。

此前测试账号的 Get-Recipient 没有 DomainController 参数；生产 CU6 截图中的 View-Only Recipients 根角色包含该参数。程序按实际会话能力决定这个只读冲突查询是否传入 DC，其他目录读写仍固定到配置的 DC。缺少写入或回读参数时，在对应写入前报错。

只读检查（使用配置中的 URL、凭据文件、DC/OU/数据库，不需要 API token）：

```bash
.venv/bin/python -B automation/direct/exchange_psrp.py --check
```

预检成功只代表连接、命令元数据和只读查询成功，不证明 OU/数据库/组的实际写入权限。必须再做隔离业务验收。healthz 只表示 Go 进程存活，不能替代上述检查。

测试专用 automation/krb5.test.conf 不得用于生产。生产 Kerberos 使用内网 DNS/KDC、实际 realm/SPN 和正确的时间同步，不需要委派或 Linux 加域。既有 HTTPS 端点若支持且组织允许 NTLM，可以显式选择它；未做真实 NTLM 路径验收，不能假设端点支持。

## 依赖与离线交付

控制端：Linux、Go 1.22+、Python 3.9；直连依赖 pypsrp 0.8.1、gssapi 1.12.0、krb5 0.10.0，见 requirements-direct.txt。默认不安装 Ansible 或 Windows collection。固定版本兼容当前环境，不代表旧运行时仍处于上游安全维护期；生产运行时升级需另做兼容验收。

生产内网完全不能访问互联网。建号脚本不下载组件、不访问微软官网做测试；代码中的 `schemas.microsoft.com` 只是 Exchange 协议标识，实际连接的是内网 Exchange。程序运行使用内网 DNS、AD/KDC、Exchange 和时间同步，不要求访问公网。

**以下准备命令只在外网构建机执行，不能拿到隔离内网直接执行。** 构建机须与生产控制机 OS、架构、Python ABI 相同；gssapi/krb5 编译通常需要 gcc、Python 开发头文件和 krb5-devel。用隔离虚拟环境安装、冻结依赖和打包：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-direct.txt
GOCACHE=/tmp/exchange-go-cache CGO_ENABLED=0 go build -o bin/exchange-automation ./cmd/exchange-automation
.venv/bin/python -m pip freeze > requirements.lock
.venv/bin/python -m pip wheel -r requirements.lock -w wheelhouse
```

内网交付应包含二进制、automation/direct 目录、配置模板、完整 Python wheelhouse、requirements.lock 及 SHA256 清单。requirements-direct.txt 固定直接依赖；**传递依赖也必须在构建环境冻结并随交付保存**。锁文件仅使用包名和固定版本，不包含公网 URL、Git 地址或可编辑安装。另行备齐匹配目标系统的 Python/venv/pip、Kerberos/GSSAPI 运行库及其系统依赖的离线安装包；不能假定 wheelhouse 包含操作系统依赖。

**内网只安装已交付的本地包**，不构建、不访问包索引、不检查 pip 在线更新：

```bash
python3 -m venv .venv
.venv/bin/python -m pip --isolated --disable-pip-version-check install \
  --no-index --find-links=wheelhouse --only-binary=:all: -r requirements.lock
```

缺包时停止并回外网补齐交付包，不临时开公网下载。不要在不同 OS/架构之间直接复制现有 /tmp Python 包目录。启动时工作目录需为交付根目录。

若需要保留旧连接回退，再安装 requirements.txt 与 requirements.yml，并交付整个 automation 目录及固定 collection 离线包。旧方式使用 [独立配置模板](deployment/legacy-ansible.env.example)，仍需要原来的 Windows 端点权限和 Kerberos 委派；不会自动切换。

## 安全机制与验证

直连将参数作为 JSON 从 Go 的 stdin 管道交给独立 Python 进程，不生成请求临时文件，不在命令行中放密码，不经过 Jinja/PowerShell 字符串求值。New-Mailbox 密码通过 PSRP SecureString 传输；只使用 add_cmdlet/add_parameter，兼容 Exchange NoLanguage 端点。

执行器使用独立进程组，超时终止本地子进程；这不等于撤销已发出的远端操作。结果必须同时满足进程成功退出、单个结构化 JSON 及必需字段/对象 GUID 校验。保留原有业务互斥、并发限制、pending 日志和人工核实流程。

旧 Ansible 回退路径仍保留 unsafe 模板保护、0600 临时文件及 SecureString 绑定，操作结束清理运行目录；SIGKILL/断电不保证旧路径临时文件立即清理。

日志记录请求 ID、动作、已确认结果、失败步骤/目标和经过限制的错误类型，不记录请求体、密码或原始 Exchange 异常。终端用户身份由网关审计，并与后端生成的 X-Request-ID 关联。

```bash
go test -race ./...
go vet ./...
.venv/bin/python -B -m unittest discover -s automation/tests -p test_direct.py -v
```

直连回归模拟 Exchange 业务数据，并用真实 pypsrp 验证非脚本命令绑定及 SecureString 序列化，无服务器访问。未安装 pypsrp 时两项协议测试会跳过；验收时应安装依赖后确保没有跳过。

旧路径的真实 Ansible 模板回归只替换 Windows action；没有 Ansible 时跳过。PowerShell 模拟回归在 automation/tests/regression.ps1。历史真实 Exchange 联调报告 [verification-2026-09-20.md](docs/verification-2026-09-20.md) 对应旧连接，不能代替新直连的实际验收。新路径验证状态见 [直连改造验证报告](docs/verification-direct-2026-09-20.md)。
