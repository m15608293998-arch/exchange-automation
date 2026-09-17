# Exchange 2019 员工邮箱自动化

这是一个最小化的 Go + Ansible 服务。Go 提供 HTTP API、输入校验和业务编排；Ansible 通过基于 WinRM 的 PSRP 把独立 PowerShell 脚本送到 Exchange Server 2019 执行。

项目只执行以下 Exchange 管理命令：

- `New-Mailbox`
- `Get-Mailbox`、`Get-Recipient`、`Get-User`
- `Get-DistributionGroup`、`Get-DistributionGroupMember`
- `Add-DistributionGroupMember`
- `Remove-DistributionGroupMember`

离职流程不会删除或禁用 AD User、Mailbox，也不会修改邮箱地址。动态通讯组不会被处理，因为发现和校验组时只使用 `Get-DistributionGroup`。

## 设计约定

- 邮箱 FirstName、Name、Alias 和 SamAccountName 都使用 `login_name`，与提供的生产截图一致。
- UPN 和主邮箱地址均为 `<login_name>@bjwgby.com`，域名可配置。
- `DisplayName` 使用调用方传入的中文或其他显示名。
- 初始密码由上游账号脚本通过 `initial_password` 传入，不出现在响应和应用日志中。
- 默认不要求用户下次登录修改密码，与提供的生产截图一致。
- OU 和 Mailbox Database 留空时由 Exchange 选择默认位置；明确知道生产值后可分别配置。
- API 本身暂不鉴权，默认只监听 `127.0.0.1`，预期由主项目的 Keycloak 网关保护。
- 不存在的离职用户返回 `404`，避免把拼错的账号误认为成功；存在但已经不属于任何组的用户返回成功和空列表。

## 项目结构

```text
cmd/exchange-automation/       Go 服务入口
internal/api/                  HTTP 路由、响应和无敏感信息的访问日志
internal/exchange/             参数校验与入职/离职编排
internal/ansible/              安全调用 ansible-playbook 并解析结果
automation/inventory/          WinRM inventory
automation/playbooks/          通用操作 playbook
automation/scripts/            独立 Exchange PowerShell 脚本
```

## 环境准备

Linux 控制端需要 Go 1.22+、Ansible Core、PSRP/Kerberos Python 依赖和 `ansible.windows` collection。CentOS/RHEL 在没有预编译 wheel 时还需要开发头文件：

```bash
dnf install -y gcc python39-devel krb5-devel
python3 -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

Exchange 主机需要启用 PowerShell Remoting，并允许 RBAC 服务账号访问 `Microsoft.PowerShell` 会话端点。默认连接方案是测试环境已验证的 PSRP/WinRM HTTP 5985 + Kerberos。Kerberos 会自动获取并委派服务账号票据，HTTP 上传输的 PSRP 消息仍由 Kerberos 加密；不需要启用 CredSSP，也不需要把账号加入 Administrators。

可在 Exchange 主机检查远程端点权限和账号状态：

```powershell
Get-PSSessionConfiguration -Name Microsoft.PowerShell | Format-List Name,Permission
Get-User svc_exchange_auto | Format-List RemotePowerShellEnabled
```

端点 ACL 应包含服务账号，且 `RemotePowerShellEnabled` 应为 `True`。外层 PSRP 会话必须允许 Kerberos 凭据委派，因为脚本会从标准 PowerShell 端点建立到本机 Exchange `/PowerShell/` 端点的受限 RBAC 会话。

测试节点无法通过 DNS 发现 KDC，因此仓库提供了测试专用的 `automation/krb5.test.conf`：

```bash
export KRB5_CONFIG="$PWD/automation/krb5.test.conf"
```

生产内网应优先使用系统 `/etc/krb5.conf` 和内网 DNS，不要照搬测试 KDC 地址。部署时必须把 `EXCHANGE_HOST`、`EXCHANGE_SERVER_FQDN` 和 Kerberos realm 改为生产值。若生产 WinRM 使用 HTTPS/5986，只需调整端口、协议和证书校验配置。

## 配置

`.env.example` 列出了全部选项。程序不会自动读取 `.env`；生产环境应由 Secret、systemd 或容器平台注入环境变量。至少需要设置 WinRM 密码：

```bash
export EXCHANGE_WINRM_PASSWORD='replace-with-secret'
```

不要把真实密码写入 `.env.example`、inventory、启动参数或 Git。服务账号密码只由 Ansible 从进程环境读取。每次 API 请求中的员工初始密码会写入权限为 `0600` 的临时变量文件，执行结束立即删除；Ansible 使用 `sensitive_parameters` 将其绑定为 PowerShell `SecureString`，对应任务同时启用了 `no_log: true`。

常用配置如下：

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `HTTP_ADDRESS` | `127.0.0.1:8080` | HTTP 监听地址 |
| `EXCHANGE_MAIL_DOMAIN` | `bjwgby.com` | 邮箱主域 |
| `EXCHANGE_ORGANIZATIONAL_UNIT` | 空 | 空值表示 Exchange 默认 OU |
| `EXCHANGE_MAILBOX_DATABASE` | 空 | 空值表示 Exchange 自动选择数据库 |
| `EXCHANGE_RESET_PASSWORD_ON_NEXT_LOGON` | `false` | 是否强制下次登录修改密码 |
| `EXCHANGE_BYPASS_GROUP_MANAGER_CHECK` | `true` | 增删组成员时绕过组所有者检查；RBAC 需允许该参数 |
| `EXCHANGE_OPERATION_TIMEOUT` | `5m` | 一次完整 HTTP 业务操作的超时；通讯组较多时应相应调大 |
| `EXCHANGE_HOST` | `192.168.6.77` | Exchange 主机地址 |
| `EXCHANGE_WINRM_USER` | `svc_exchange_auto@EXCHLAB.LOCAL` | WinRM/RBAC Kerberos 主体 |
| `EXCHANGE_WINRM_PASSWORD` | 无 | 必填，必须来自 Secret 或环境变量 |
| `EXCHANGE_WINRM_PORT` | `5985` | PSRP/WinRM 端口 |
| `EXCHANGE_WINRM_SCHEME` | `http` | PSRP/WinRM 协议；Kerberos 提供消息加密 |
| `EXCHANGE_PSRP_AUTH` | `kerberos` | PSRP 认证方式 |
| `EXCHANGE_SERVER_FQDN` | `exchlab.exchlab.local` | Kerberos SPN 使用的 Exchange FQDN |
| `EXCHANGE_KERBEROS_SERVICE` | `HTTP` | 当前 Exchange/WinRM 注册的 SPN 服务名 |
| `EXCHANGE_IGNORE_PROXY` | `true` | 私网 Exchange 连接不经过控制节点代理 |
| `EXCHANGE_WINRM_CERT_VALIDATION` | `ignore` | 使用 HTTPS 时的证书策略；生产建议 `validate` |
| `KRB5_CONFIG` | 系统默认 | 测试环境可指向 `automation/krb5.test.conf` |

也可以通过 `ANSIBLE_INVENTORY` 指向自己的 inventory 文件，覆盖主机、端口和认证配置。

## 启动和检查

先导出配置、验证 PSRP/WinRM，再启动服务：

```bash
export KRB5_CONFIG="$PWD/automation/krb5.test.conf"
ansible exchange_servers -i automation/inventory/hosts.yml -m ansible.windows.win_ping
go test ./...
go run ./cmd/exchange-automation
```

存活检查：

```bash
curl http://127.0.0.1:8080/healthz
```

`healthz` 只表示 Go 进程可用，不会主动连接 Exchange。

## 入职 API

```http
POST /api/exchange/users
Content-Type: application/json

{
  "login_name": "slpeng",
  "display_name": "江流",
  "initial_password": "由上游脚本生成的密码",
  "groups": ["全体员工", "研发部"]
}
```

`groups` 接受 Exchange `Get-DistributionGroup -Identity` 能唯一识别的名称、别名、SMTP 地址或 GUID。重复组会在 Go 中去重。

首次创建返回 `201 Created`：

```json
{
  "login_name": "slpeng",
  "display_name": "江流",
  "primary_smtp_address": "slpeng@bjwgby.com",
  "created": true,
  "added_groups": ["all@bjwgby.com"],
  "existing_groups": []
}
```

完全相同的邮箱已经存在时不会再次执行 `New-Mailbox`，返回 `200 OK`、`created: false`，并继续幂等地确认组成员关系。如果 login、UPN 或邮箱地址被其他对象占用，则返回 `409 RECIPIENT_CONFLICT`。

## 离职 API

```http
POST /api/exchange/users/slpeng/offboard
```

成功响应：

```json
{
  "login_name": "slpeng",
  "removed_groups": ["all@bjwgby.com", "dev@bjwgby.com"]
}
```

服务先读取该邮箱所属的所有静态 Exchange Distribution Group，再由 Go 逐组调用 `Remove-DistributionGroupMember`。重复调用时，第二次返回 `removed_groups: []`，AD 用户、Mailbox 和邮箱地址始终保留。

组操作发生部分失败时，错误响应会带 `partial_result`。已经完成的动作不回滚；相同请求可安全重试并继续完成剩余组。

## HTTP 状态码

| 状态码 | 场景 |
|---|---|
| `200` | 幂等成功或离职成功 |
| `201` | 新邮箱创建成功 |
| `400` | JSON 或参数校验失败 |
| `404` | 离职目标邮箱不存在 |
| `409` | login/邮箱地址被其他对象占用 |
| `422` | 请求指定的通讯组不存在 |
| `502` | Ansible、WinRM 或 Exchange 命令失败 |
| `504` | 完整业务操作超时 |

应用日志只记录 HTTP 方法、路径、状态、耗时和稳定错误码，不记录请求体、初始密码或 WinRM 密码。
