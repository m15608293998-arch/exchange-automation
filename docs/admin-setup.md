# 给 Exchange 管理员：服务账号初始化

当前业务部署在 Exchange 本机时，账号仍由本脚本创建；Python 服务安装及离线交付请看 [本机服务说明](windows-local-service.md)。本页后续 Linux 连接内容仅适用旧部署路径。

生产只读采集结果已收到并完成适配，见 [生产环境记录](production-environment-2026-09-20.md)。管理员现在可以审核并执行本文的建号步骤；只读采集脚本和本建号脚本是两个不同阶段。

## 要达到的效果

业务要覆盖全公司，权限按“允许做什么”收紧，而不是按员工 OU 或通讯组名单划分。

| 允许 | 不允许 |
|---|---|
| 组织范围创建普通员工 AD 用户和邮箱 | 删除/禁用邮箱或用户、修改已有用户密码 |
| 查询用户、邮箱、收件人、组及成员 | 读取邮件内容、授予邮箱 FullAccess/SendAs |
| 添加/移除所有普通静态通讯组的成员，新组自动包含 | 修改安全组/动态组，创建/删除通讯组，批量替换整个组成员列表 |
| 通过 Exchange `/PowerShell/` 登录 | 不新增 Windows 管理权限或 RDP 授权，不授予角色授权管理和服务器配置修改权限 |

“所有人”仍受本项目业务约定约束：只支持普通 UserMailbox，入职前 AD 用户不存在；当前单个部署使用一个员工 UPN 后缀、邮箱域和 DC。已有员工 UPN 不匹配配置时会拒绝处理，不会为了扩大覆盖而移除身份核对。

## 管理员只需要这样做

1. 将 [Initialize-ExchangeAutomation.ps1](../deployment/Initialize-ExchangeAutomation.ps1) 复制到内网 Exchange 服务器，例如 `C:\ExchangeAutomation`。
2. 用**同时具有 AD 创建用户权限和 Exchange 角色管理权限**的管理身份，打开该服务器的 **64 位 Windows PowerShell 5.1** 或 Exchange Management Shell。普通 Windows PowerShell 下脚本会尝试加载该服务器已有的 Exchange 管理环境；加载失败时直接打开 Exchange Management Shell 即可。不支持 PowerShell 7。
3. 执行下面命令，只输入**要新建的账号名**和**这个新账号的密码**，其余自动处理。

```powershell
cd C:\ExchangeAutomation
.\Initialize-ExchangeAutomation.ps1
```

例如第一次提示输入 `svc_exchange_app`（不用写域名），第二次输入新密码，成功后返回：

```text
svc_exchange_app@实际AD域名
```

账号名支持 1–20 位英文字母、数字、下划线、连字符，首位为字母或数字。域名、域控和 Exchange 连接地址自动发现。**不会再要求选择邮箱域、数据库、员工 OU 或通讯组名单**，也不需要新建员工 OU。服务账号不创建邮箱、不加入管理员组。

按本项目要求，脚本设置**服务账号密码永不过期、首次登录无需修改密码**；AD 密码复杂度要求仍然有效。输入的是新服务账号密码，**不是管理员密码**。这是普通 AD 用户，自身没有邮箱；`账号@域名` 是登录名，普通域用户的既有默认权限仍受域策略控制。

若输入的账号已经存在，脚本会停止，不改已有密码、不额外授权。换一个新名称即可。需要自动化调用时，也保留账号名和 SecureString 密码参数；普通管理员不必使用：

```powershell
.\Initialize-ExchangeAutomation.ps1 -ServiceAccountName svc_exchange_app
```

如需预览（可选，不属于正常操作步骤）：

```powershell
.\Initialize-ExchangeAutomation.ps1 -ServiceAccountName svc_exchange_app -WhatIf
```

`-WhatIf` 不询问密码、不创建用户、不修改角色、不生成交付文件。高级调用仍可用 `-DomainController` 指定同域可写 DC，用 `-OutputDirectory` 指定一个尚不存在的报告目录；默认不用填。旧版 `-MailDomain`、`-MailboxDatabase`、`-EmployeeUPNSuffix`、`-EmployeeOrganizationalUnit` 参数已移出本建号脚本，员工业务设置由程序部署配置管理。

## 完全隔离内网

管理员只需复制这个 `.ps1` 文件，使用服务器已有的 Windows/.NET 和 Exchange 管理组件；脚本不探测互联网，不下载模块，也不访问微软官网做测试。需要连通的是真实内网的 AD/DNS/Kerberos 和 Exchange 服务。

代码里的 `http://schemas.microsoft.com/powershell/Microsoft.Exchange` 是 **WSMan 的 Exchange 会话标识（ShellUri）**，不是网络请求目标，不能替换成公司域名。真正的连接地址（ConnectionUri）由本机 Exchange FQDN 生成：`http://内网Exchange服务器/PowerShell/`。登录验证显式禁用代理和连接重定向。管理 Shell 启动横幅或本文中的官网链接只是说明，不要求管理员打开网页。

Linux 应用运行所需的 Python、Kerberos 运行库和 Python 包由应用维护方提前准备离线安装包，见 [离线交付步骤](../README.md#依赖与离线交付)；不是让 Exchange 管理员联网安装。脚本不会修改现有执行策略或证书策略来绕过组织要求。

## 成功后给应用维护方什么

把成功返回的**完整账号名和刚才设置的密码**交给应用维护方即可；不需要记忆或手工拼装权限。密码不回显、不写入文件。

脚本同时自动保留 `exchange-handoff-<随机标识>` 文件夹，方便应用维护方查连接信息和故障，管理员无需填写这些文件：

- `setup-report.json`：服务账号、GUID、连接地址、DC、角色、检查结果。
- `connection.env.example`：仅含连接配置，不是完整应用配置，不能覆盖已有员工邮箱域、数据库等业务设置。使用 systemd EnvironmentFile 语法，**不要当 shell 脚本 source 执行**。

需要时可同时提供以上两份文件；**服务账号密码通过安全渠道另外交付**。文件在管理员本地磁盘保存，不要选择公共共享目录。

脚本输出的服务账号登录名可以直接使用；直连程序会在 Kerberos 连接前统一处理 `账号@AD域` 中域后缀的大小写。管理员不必手工改成大写，也不需要修改 AD 账号。密码仍区分大小写。

员工邮箱域、UPN 后缀、数据库、可选创建位置及 Linux DNS/Kerberos 等仍属于程序部署配置，不是服务账号创建的输入。应用维护方负责这些配置及 Linux `--check`、隔离业务测试；管理员不需要处理 Linux 0600 文件、Ansible 或 Python 安装。两个输入简化的是管理员建号过程，不表示程序可以不配置业务环境。

本业务只有一个员工邮箱后缀，保留在应用 `EXCHANGE_MAIL_DOMAIN` 中配置一次，建号时不询问。它是员工邮箱地址的 `@` 后缀，不是服务账号必须拥有的邮箱；服务账号返回的 `账号@AD域` 是登录名。数据库可以有一个或多个，不根据软件版本猜测，也不在建号时选择。

本次生产配置已按截图填好员工邮箱后缀和数据库。应用部署使用 [生产配置模板](../deployment/bjwgby-production.env.example)，管理员无需选择。这两个值是应用配置，并非服务账号的 RBAC 值限制。

应用维护方拿到生产新账号后，按 [内网迁移配置清单](intranet-migration.md) 修改地址、凭据、员工业务和 Kerberos 配置，不需要管理员修改项目源码。

## 脚本具体做了什么

- 使用 Windows 自带 .NET 目录接口创建普通域账号，不要求额外安装 AD PowerShell/RSAT 模块。账号初始禁用；要求非空且符合域复杂度的密码，设置密码永不过期并取消首次改密，禁止凭据委派，不加管理员组，不创建服务账号邮箱。
- 创建 4 个带 `EA-<服务账号名>-` 前缀的专用子角色：只读收件人、普通邮箱创建、普通通讯组成员维护、组主管检查绕过。后两者共同提供成员维护需要的参数，使用相同的普通组类型范围；管理员不需要手工组合权限。
- 自动建立“RecipientTypeDetails 为 MailUniversalDistributionGroup”的组类型范围，覆盖所有当前及未来普通通讯组；没有按 OU、组名或成员白名单限制。
- 如果环境中已经存在过滤条件、RecipientRoot 和 Exclusive 属性完全相符的普通组范围，脚本会严格回读后复用；不会创建 Exchange 不允许的重复范围，也不会复用更宽或带 OU 根的范围。
- 先裁剪新角色中的非业务命令，再分配到新账号；只裁剪本次新建角色，不改内置角色、旧角色或任何现有账号。
- 启用 Exchange RemotePowerShellEnabled，核对角色及参数，启用账号，再以新账号建立真实 Exchange 会话，查询命令元数据和一条通讯组记录。若已经登录但所需命令/参数暂缺，间隔 5 秒刷新会话，最多检查 3 次；认证失败或查询报错立即停止。
- 不自动修改 WinRM 配置、证书、SPN、委派、网络防火墙、已有企业隔离策略，也不创建/删除业务邮箱或通讯组。

写角色只保留业务所需参数，防止转而创建共享/资源/系统邮箱。查询角色保留父角色的查询参数，避免不必要地损害兼容性。

脚本以 UTF-8 BOM 保存，便于 Windows PowerShell 5.1 正确读取中文；每个函数标注“只读 / 写入 / 连接 / 验证”等用途，主流程按 1–8 步注释。脚本只向内部 AD/Exchange 发请求。

## 如果脚本报错

不能把“有账号生成了”当作成功，必须看到 `SUCCESS` 和报告中的 `provisioned_and_read_check_passed`。

发生部分失败时，脚本尝试禁用本次新建账号，保留已创建角色和报告，**不删除账号、角色或已有数据**。若无法确认已禁用，会输出明确警告，请管理员立即核查。部分对象可能残留，因此不要反复运行来叠加权限；将失败阶段和报告交给应用维护方分析。脚本不会为了成功自动分配更宽角色。

有限次数的权限刷新不能覆盖任意长的缓存延迟；超过次数仍按失败处理。脚本没有自动接管旧账号或重置其密码的恢复模式，避免仅凭同名对象或可修改的报告重新启用错误账号。

常见原因包括：执行者只有本地管理员权而没有 AD/RBAC 管理权限、密码不符合域策略、RBAC/AD 尚未复制完成、企业独占管理范围、AD split permissions、HTTP Exchange 端点被组织策略禁用等。不能保证一个脚本越过这些既有策略；也不应通过关闭安全设置来解决。

`SUCCESS` 验证的是**服务器本地新账号的登录、命令参数和一次读取**，不等于 Linux 网络已连通，也不等于数据库、AD ACL 和所有通讯组写入均已验收。

## 当前验证状态

- 二次实机复验再次创建全新账号，并通过 app/dev 短名称、创建 AD+邮箱、加入/移出两个组及幂等验收；发现的 Linux 登录名 Realm 大小写问题，现已在直连程序连接层统一处理，无需修改脚本生成的账号名称。详见 [二次实机复验报告](verification-setup-recheck-2026-09-20.md)。
- 项目新直连业务流程已经在测试 Exchange 真实验证，见 [直连验证报告](verification-direct-2026-09-20.md)。
- 2026-09-21 版修改了服务密码设置、中文注释及有限次数的权限刷新；其验证结果见 [本次验证报告](verification-service-account-2026-09-21.md)。此前 95 项原生 PowerShell 回归及真实只读检查属于 2026-09-20 版本，见 [历史验证报告](verification-account-only-2026-09-20.md)，不与当前版本混同。
- 初始化脚本的 `Test-ServiceEndpoint` 函数先用原有服务账号验证了检查逻辑；随后又由新建账号实际通过同一只读检查和 Linux 端检查。
- OU 留空的配置和直连业务回归已通过。
- 已使用测试环境管理员执行完整真实初始化，新服务账号通过服务器本地只读检查、Linux Kerberos 直连检查，以及隔离邮箱创建和普通通讯组加入/移出验收。结果及联调中发现的兼容修复见 [初始化验证报告](verification-setup-2026-09-20.md)。生产环境仍需用生产管理员重新执行，并用生产新账号做隔离验收；测试通过不等于自动跨越生产的独占范围、AD split permissions、网络或域策略。

参考：[Exchange 角色范围](https://learn.microsoft.com/en-us/exchange/understanding-management-role-scopes-exchange-2013-help)、[角色参数裁剪](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-managementroleentry?view=exchange-ps)、[组主管检查所需权限](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/add-distributiongroupmember?view=exchange-ps)。
