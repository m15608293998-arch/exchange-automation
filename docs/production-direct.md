# 生产直连交付：管理员最少需要做什么

本页适用原 Linux 控制端。新的 Exchange 本机 Python 服务请看 [本机服务说明](windows-local-service.md)。

本项目默认连接 `http(s)://Exchange服务器FQDN/PowerShell/` 的 `Microsoft.Exchange` 端点。
Linux 上编排业务，PSRP 只提交固定命令和类型化参数，不在 Windows 上运行通用脚本。

完全隔离内网、换用生产 Exchange 地址时，按 [内网迁移配置清单](intranet-migration.md) 修改部署配置；管理员脚本不访问微软官网测试，也不在线安装组件。

## 与旧方式相比

| 项目 | 旧 Ansible 双跳 | 新 direct 直连 |
|---|---|---|
| 管理连接 | Linux → Windows PowerShell → Exchange | Linux → Exchange |
| 普通 Microsoft.PowerShell 端点访问权 | 需要 | 不需要 |
| 给控制机开放 5985/5986 | 需要 | 不需要；仅开放现有 Exchange 端点的 80 或 443 |
| Kerberos 凭据委派/第二跳 | 需要 | 不需要，客户端明确禁止委派 |
| Linux Ansible / Windows collection | 需要 | 不需要 |
| 域管理员、本地管理员、RDP 权限 | 不应作为默认方案 | 不需要 |
| Exchange 服务自身的 WinRM/远程管理组件 | 需要 | 仍由 Exchange 自身使用，不得停用/卸载 |
| 专用普通 AD 服务账号、Exchange RBAC | 需要 | 仍需要，这是业务授权边界 |

端点使用受限 NoLanguage 模式。不要为本应用改成 FullLanguage，不安装自定义高权限端点，不关闭证书校验或 Extended Protection，不启用 Basic/允许未加密传输。

## 管理员的一次性交付

推荐将 [初始化脚本](../deployment/Initialize-ExchangeAutomation.ps1) 和 [管理员一页说明](admin-setup.md) 一起交给管理员。在 Exchange 服务器本地执行，自动准备下列内容，无需管理员手工拼装角色条目或维护组名单。

1. **新建一个普通 AD 域服务账号**，例如 `svc_exchange_auto@corp.example.com`。不需要邮箱，不授予 Domain Admins、Organization Management 或本地 Administrators。脚本对已有同名账号停止，不覆盖密码、不自动叠加授权；需复用旧账号时另行审核其有效权限。
2. **允许该账号使用 Exchange 远程 PowerShell，并授予四个专用业务角色**。普通邮箱创建使用组织写范围，不按员工 OU 限制；通讯组成员维护覆盖所有当前及未来的普通静态通讯组，不按组名称或白名单限制。组类型过滤由脚本自动建立，防止凭据被直接使用时修改安全组。成员维护参数与组主管检查绕过参数在 Exchange 内置角色中分开，脚本自动组合两个裁剪子角色，两者使用相同的普通组类型范围。
3. **只输入新账号名和密码，自动返回完整账号名**：Exchange 端点 FQDN、AD 域和域控自动发现；脚本不再询问邮箱域、数据库或 OU。账号/角色报告和仅含连接设置的 `connection.env.example` 自动保留，密码不写入输出文件。员工邮箱域、UPN 后缀、数据库、可选创建 OU 由应用维护方在部署配置中指定，不会在建号时猜测或覆盖已有业务配置。

执行脚本的管理员需要 AD 建号权限和 Exchange RBAC 角色管理权限；单纯“以本地管理员运行”并不等于有这两项权限。这些是安装者权限，不是授予应用服务账号的权限。

服务账号和员工账号是两类账号。当前初始化脚本按要求创建无邮箱的服务账号，设置密码永不过期、无需首次改密。不要将管理员密码放入应用；使用专用服务账号密码。凭据文件是 `{ "username": "svc@corp.example.com", "password": "..." }`，权限 0600，由 Linux 服务用户读取。将来如主动更换服务密码，需同步更新应用凭据。

`EXCHANGE_AUTH=kerberos` 时，`账号@AD域` 的域后缀可写成小写、大写或混合大小写；程序在认证前统一为 AD 使用的大写 Realm，环境变量和凭据文件两种配置方式都适用。保留用户名本体和密码原样，不修改凭据文件、AD UPN、员工邮箱参数或服务器权限。密码仍区分大小写；NTLM 登录名不做此转换，也不会把 `DOMAIN\账号` 或邮箱别名后缀猜成另一个 Realm。Linux 仍需配置正确的实际 AD Realm/KDC。

### 最小命令与参数清单

| 命令 | 需要保留的业务参数 |
|---|---|
| Get-Mailbox | Identity、DomainController |
| Get-Recipient | Identity；DomainController 仅在该角色暴露时使用 |
| Get-User | Identity、DomainController |
| New-Mailbox | Name、FirstName、Alias、SamAccountName、DisplayName、UserPrincipalName、PrimarySmtpAddress、Password、ResetPasswordOnNextLogon、OrganizationalUnit、Database、DomainController |
| Get-DistributionGroup | Identity、Filter、RecipientTypeDetails、ResultSize、DomainController |
| Get-DistributionGroupMember | Identity、ResultSize、DomainController |
| Add-DistributionGroupMember | Identity、Member、DomainController；启用绕过组主管检查时还需 BypassSecurityGroupManagerCheck |
| Remove-DistributionGroupMember | Identity、Member、Confirm、DomainController；启用绕过组主管检查时还需 BypassSecurityGroupManagerCheck |

还会使用端点内置 `Get-Command` 查询命令元数据，并绑定通用 `ErrorAction=Stop`。
无需开放 Remove-Mailbox、Disable-Mailbox、Enable-Mailbox、New/Remove-DistributionGroup、Set-User、任意脚本或 Windows 管理命令给运行账号。

脚本按 RoleType 识别内置父角色，派生 View-Only Recipients、Mail Recipient Creation、Distribution Groups、Security Group Creation and Membership 的专用子角色，仅保留上述命令。查询命令保留父角色可用参数以兼容不同 Exchange 版本；写命令只保留业务参数和通用控制参数。**不修改内置角色，不直接分配完整父角色**；先裁剪及回读确认，再分配给新账号。

默认 `EXCHANGE_BYPASS_GROUP_MANAGER_CHECK=true`。脚本从 Security Group Creation and Membership 派生仅包含 Add/Remove-DistributionGroupMember 的子角色，使用普通组类型过滤范围绑定该角色；不用逐组添加服务账号为组主管，也不给完整 Organization Management。

**权限注意事项：**

- 自定义写范围不等于自定义读范围；Exchange RBAC 读取范围可能更宽，必须单独审计。
- 普通组类型范围覆盖全组织的普通通讯组，既不是单个员工 OU，也不是人工组名单。成员参数不做员工白名单限制；持有服务账号凭据者可影响这些普通组的成员，必须保护该凭据。
- 裁剪参数不能普遍限制参数值。本方案刻意不增加 OU 或数据库级 RBAC 写范围；应用配置的数据库/可选 OU 是创建位置，不应被描述为凭据自身的授权限制。
- RBAC 权限会叠加。账号若已有宽权限角色，新增窄范围角色不会抵消原来的权限。
- 不会根据一次读取成功自动判定写入范围正确；必须做授权范围内外的隔离验收。
- 全组织 RBAC 不绕过既有独占管理范围、AD split permissions、对象 ACL 或跨域限制。脚本发现独占范围时提示；不修改企业已有隔离策略，也不额外枚举整个林的域和 UPN 后缀。当前应用每个部署使用一个员工 UPN 后缀、一个邮箱域和一个 DC；多域/多后缀业务需单独验收，不能仅扩大 RBAC 就声称已支持。

## 认证选择

优先使用现有端点支持的方式，不要求管理员为了应用另开协议：

- `EXCHANGE_AUTH=kerberos`（默认）：HTTP 下强制消息加密；HTTPS 校验服务器证书。Linux 需要能解析 AD/Exchange DNS、访问 KDC，并保持时间同步。**不要求 Linux 加入域，也不要求凭据委派**。普通 Kerberos 配置属于控制机部署工作，可由应用维护人员完成。
- `EXCHANGE_AUTH=ntlm`：仅允许使用已有且支持 NTLM 的 **HTTPS** Exchange 端点，严格校验证书、保留 CBT。可以不依赖 Linux Kerberos 配置，但须符合域策略；不能假定所有 Exchange 虚拟目录都支持它，也不建议为简化而放开组织已禁用的 NTLM。该可选路径尚未做真实服务器验证。

2026-09-20 已用测试机现有服务账号完成 **HTTP + Kerberos 直连真实联调**；随后又由初始化脚本创建全新受限账号 `svc_exa260920060300@exchlab.local`，完成 Linux 登录、危险命令暴露检查、创建 AD+邮箱、普通通讯组加入/移出、幂等重试与邮箱保留验收。详见 [直连报告](verification-direct-2026-09-20.md) 和 [初始化账号报告](verification-setup-2026-09-20.md)。这不代替生产账号范围验收，也不证明 HTTPS/NTLM 路径已验证。

禁止自动从 Kerberos 降级到 NTLM/Basic。使用 Exchange 节点真实 FQDN，避免为一个别名额外配置 SPN。HTTPS 时域名必须匹配证书；内部 CA 应通过 REQUESTS_CA_BUNDLE 或系统信任链提供。

## 应用维护人员执行的只读预检

安装 `requirements-direct.txt` 后，向环境注入连接信息；不需要 API_TOKEN，也不需要启动 HTTP 服务：

```bash
export EXCHANGE_POWERSHELL_URL=http://exchange01.corp.example.com/PowerShell/
export EXCHANGE_AUTH=kerberos
export EXCHANGE_CREDENTIAL_FILE=/etc/exchange-automation/credentials.json
export EXCHANGE_DOMAIN_CONTROLLER=dc01.corp.example.com
export EXCHANGE_ORGANIZATIONAL_UNIT='OU=Employees,DC=corp,DC=example,DC=com'
export EXCHANGE_MAILBOX_DATABASE=DB01
.venv/bin/python -B automation/direct/exchange_psrp.py --check
```

检查连接、命令/参数元数据，并执行一条普通通讯组只读查询；不会创建用户或修改组。输出 `ok=false` 时退出码为 1。认证、DNS、TLS、依赖缺失等只返回错误类型，不输出原始异常或密码。
若缺少权限，结构化输出的 data 会列出缺少的命令/参数。某些端点的元数据查询本身拒绝访问时，只能报告对应失败类别，需要管理员在 EMS 检查。

管理员可在 Exchange Management Shell 做如下只读核对：

```powershell
Get-User svc_exchange_auto | Format-List Name,RemotePowerShellEnabled
Get-ManagementRoleAssignment -RoleAssignee svc_exchange_auto |
    Format-Table Name,Role,RecipientWriteScope,CustomRecipientWriteScope
Get-PowerShellVirtualDirectory | Format-List Identity,InternalUrl,*Authentication*,ExtendedProtection*
```

角色组继承、宽角色以及实际有效权限仍需管理员完整核对，不能仅凭上述简短输出认定最小权限成立。

预检通过后，用隔离测试用户、数据库和既有普通测试通讯组做入职/重试/离职清理，确认 AD 用户和邮箱保留，并确认安全组及非业务命令不能被操作。无需为了此项目新建员工 OU；也不能拿真实员工做破坏性测试。初始化脚本自身只做新服务账号配置与只读登录检查，不创建业务测试邮箱。

## 迁移与回退

业务 API 参数、返回值、状态目录、待核实记录均保持原约定。默认模式改为 direct，旧配置不会被静默猜测或自动回退；部署必须明确配置新 URL 和凭据来源。

旧实现保留，仅在 `EXCHANGE_CONNECTION_MODE=ansible` 时使用。需要回退时先停止服务并确认无未结束的远端命令，保持原 EXCHANGE_STATE_DIRECTORY，使用 [旧连接配置](../deployment/legacy-ansible.env.example) 和对应依赖重启。不要清理 pending 记录来绕过不确定状态。

## 依据

- [Microsoft：直接连接 Exchange 远程 PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-servers-using-remote-powershell?view=exchange-ps)
- [Microsoft：受限 Exchange 端点必须使用 AddCommand 而非 AddScript](https://support.microsoft.com/en-us/servicing/exchange/update/2021/the-syntax-is-not-supported-by-this-runspace-error-after-installing-april-2021-exchange-security-upd)
- [Microsoft：BypassSecurityGroupManagerCheck 的授权要求](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/add-distributiongroupmember?view=exchange-ps)
- [Microsoft：管理角色分配与范围](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-managementroleassignment?view=exchange-ps)
