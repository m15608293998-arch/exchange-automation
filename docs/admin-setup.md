# 给 Exchange 管理员：创建专用服务账号

业务运行在 Exchange 本机。此脚本只创建 AD 服务账号和 Exchange RBAC，不安装 Python、依赖或 Windows 功能；环境要求见 [本机部署说明](windows-local-service.md)。

## 执行方式

1. 把 [Initialize-ExchangeAutomation.ps1](../deployment/Initialize-ExchangeAutomation.ps1) 复制到 Exchange 服务器。
2. 使用同时具备 AD 建号和 Exchange RBAC 管理权限的管理员，打开 **64 位 Exchange Management Shell / Windows PowerShell 5.1**（不是 PowerShell 7）。
3. 在脚本目录执行，只输入新账号短名称和新账号密码：

```powershell
.\Initialize-ExchangeAutomation.ps1
```

账号名为 1–20 位英文字母、数字、下划线或连字符，首位为字母或数字。成功返回 `账号@实际AD域名`；这是登录名，不是服务账号邮箱。也可预先指定名称：

```powershell
.\Initialize-ExchangeAutomation.ps1 -ServiceAccountName svc_exchange_app
```

域、域控和本机 Exchange 地址自动发现，不询问员工邮箱域、数据库、OU 或通讯组名单。服务账号密码永不过期、不要求首次登录修改；密码仍需满足 AD 复杂度策略。账号已存在时直接停止，不改密码、不叠加权限。

## 权限和操作范围

| 允许 | 不授予 |
|---|---|
| 创建组织内普通员工 AD 用户和邮箱 | 删除/禁用邮箱或用户、修改已有用户密码 |
| 查询用户、邮箱、收件人、组和成员 | 读取邮件内容、邮箱 FullAccess/SendAs |
| 维护所有普通静态邮件通讯组的单个成员 | 修改安全组/动态组，创建/删除组，批量替换组成员 |
| 使用本机 Exchange PowerShell 端点 | 域/本地管理员、RDP、角色授权管理、服务器配置修改权限 |

脚本先只读检查环境和名称冲突，使用 Windows 自带 .NET 创建普通域账号，初始禁用、禁止凭据委派，不给账号建邮箱，不加入管理员组。

随后创建 4 个 `EA-<账号名>-` 专用子角色，只保留本程序需要的 8 个业务命令。查询角色保留父角色参数；写命令只保留业务参数。成员维护和组主管检查绕过角色使用同一个普通通讯组类型范围，不要求逐组添加组主管，不按员工 OU 或组名单限制。只读查询必须支持 `Get-DistributionGroup -Filter`。

角色先裁剪、回读，再分配并启用账号；不修改内置角色、已有角色或其他账号。若已有完全相符的普通组范围，严格核对后复用，否则新建；不会复用更宽或 OU 限定范围。

最后以新账号连接本机 Exchange 端点，核对命令及参数并执行只读查询。权限缓存暂缺时有限重试；认证/查询失败不自动扩大权限。

## 完全隔离内网

脚本只依赖服务器已有 Windows/.NET/Exchange 管理组件，不访问公网、不下载组件，不修改 WinRM、防火墙、证书、执行策略或域策略。服务器自身的 Exchange PowerShell/WinRM 组件需正常运行。

代码中的 `http://schemas.microsoft.com/powershell/Microsoft.Exchange` 是协议会话标识，不是访问微软网站。真正连接地址根据本机 FQDN 生成，登录验证禁用代理和重定向。执行策略阻止脚本时，由管理员按既有审批或签名流程处理，不要求 Bypass。

可选预览不询问密码、不写用户、角色或交付文件：

```powershell
.\Initialize-ExchangeAutomation.ps1 -ServiceAccountName svc_exchange_app -WhatIf
```

## 成功后交付什么

将返回的完整账号和密码通过安全渠道交给应用维护方。密码不回显、不写报告。服务注册支持 `账号@AD域` 和 `AD域\账号`；业务运行使用 Windows 服务身份，不在 HTTP 请求中传服务账号密码。

脚本在管理员本地保留 `exchange-handoff-<随机标识>` 目录：

- `setup-report.json`：账号、GUID、域控、Exchange 地址、角色和检查结果。
- `connection.env.example`：历史格式的连接信息清单，仅供查询；当前本机服务不加载它，不要执行或覆盖业务 JSON 配置。

员工邮箱域和数据库已经放在 [生产配置示例](../deployment/config.example.json) 中：`bjwgby.com`、`Mailbox Database 1119980504`，建号时无需选择。它们是业务配置，不是账号 RBAC 的参数值限制。部署人员仍须手动准备“作为服务登录”、代码只读、状态目录可写等条件。

## 报错与验收

必须看到 `SUCCESS` 和报告状态 `provisioned_and_read_check_passed`，不能仅以账号存在判断成功。失败时脚本尝试禁用本次新账号，保留角色和报告用于排查，不删除已有数据、不覆盖同名账号、不自动重置密码；禁用失败会明确告警。不要反复运行叠加权限。

`SUCCESS` 只证明账号登录、命令参数和读取正常，不代表所有业务写入已验收。AD ACL、独占管理范围、AD split permissions、域策略及密码策略仍可能限制实际操作，程序不会绕过它们。

当前测试证据见 [本机验收](verification/local-2026-09-22.md)、[外部接口验收](verification/external-2026-09-22.md)；以前的建号记录可从 Git 历史恢复。生产仍须用生产服务账号做隔离员工创建、加组和离组验收。
