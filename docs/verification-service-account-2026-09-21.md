# 服务账号脚本变更与验证（2026-09-21）

## 交付内容

[Initialize-ExchangeAutomation.ps1](../deployment/Initialize-ExchangeAutomation.ps1) SHA-256：`d526818bae656922a848b7477033b4ebb6d70752e664b598709a8a8dd1d6ba75`。

- 只创建普通 AD 服务账号，并分配本程序使用的精简 Exchange RBAC；不调用 New-Mailbox、Enable-Mailbox 或创建员工业务对象。
- 按用户要求设置 `PasswordNeverExpires=true`；设置密码后调用 `RefreshExpiredPassword()`，取消首次登录必须改密。密码仍需满足 AD 复杂度要求。
- 仍只有新账号名和新密码两次提示，改为中文；函数按查询、写入、验证等用途注释，主流程分 8 步，使用 UTF-8 BOM 兼容 Windows PowerShell 5.1。
- 仅在认证成功、命令或参数暂缺时，间隔 5 秒新建会话检查，最多 3 次。认证失败、查询异常立即停止；最终失败尝试禁用新账号。没有自动复用已有账号、重置旧密码或扩大角色的恢复分支。
- 保留先裁剪角色再授权、同名对象保护、普通通讯组范围、报告不含密码等保护。
- 报告增加无需首次改密和未创建服务账号邮箱的说明，仍明确 `business_write_verified=false`。

## 生产配置与截图校正

员工数据库和邮箱后缀沿用已确认的 [生产应用模板](../deployment/bjwgby-production.env.example)，管理员建号时无需选择。

生产截图 View-Only Recipients 的 Get-Recipient 确实具有 DomainController 参数；已纠正 README 与回归数据。测试中的截图能力清单是相关参数子集，不是完整角色导出。程序保留按会话能力兼容无此参数的受限测试账号。

## 自动化验证

- 测试服务器原生 Windows PowerShell 5.1：128 项回归通过；此轮 AD/Exchange 写入全部模拟，真实目录写入为 0。
- 新增实际建号函数的模拟测试：密码永不过期、设密码后取消首次改密、授权前账号禁用、拒绝不合规密码；不执行创建邮箱命令。
- 新增实际连接检查函数的模拟测试：命令延迟、参数延迟、连续缺失、认证失败、元数据异常和读取异常；验证重试次数、等待间隔与会话释放。
- Python 直连单测共 36 项：34 通过，2 项可选环境测试跳过。
- 测试传输工具已按 UTF-8 BOM 解码后提交脚本文本，避免将 BOM 当成 PowerShell 命令的一部分。管理员执行磁盘上的原文件不使用此测试传输工具。

## 实机验证

在已授权的外网测试服务器（Exchange `15.2.1748.10`）执行上述哈希的原始脚本文件，测试封装仅代答账号和密码两次中文提示。创建一个独立测试服务账号，实际账号标识仅保存在本机验证证据中。

独立只读回查 AD 和脚本交付报告，结果如下：

| 核对项 | 结果 |
|---|---|
| AD 账号已启用 | `true` |
| 密码永不过期 | `PasswordNeverExpires=true` |
| 首次登录无需改密 | 实际回读 `pwdLastSet` 大于 0 |
| 允许空密码 | `PasswordNotRequired=false` |
| 允许凭据委派 | `DelegationPermitted=false` |
| 服务账号邮箱 | `homeMDB` 和 `msExchMailboxGuid` 均未设置 |
| 脚本报告 | `provisioned_and_read_check_passed`，只读验收首次检查通过 |
| RBAC | 4 个专用角色及分配；复用经过回查的普通通讯组范围 |

再使用该新账号及原始小写登录后缀，从 Linux 验证 Kerberos 直连、8 个命令及参数、只读查询和 `app` / `dev` 短名称解析，全部通过。实际端点清单只有 8 个业务命令及端点基础命令。

旧测试封装在建号后的报告回读阶段迟迟没有完成，停止该封装时返回 WinRM HTTP 400；因此不记为完整封装流程或实机重复执行验收通过。后续独立检查已成功回读同一账号及同一脚本生成的报告；“同名重复执行拒绝且不写入”由本轮模拟回归验证。这是测试封装与交付脚本的不同验证范围。

完整证据保存在开发机仓库外的私有测试目录。测试账号及 4 个专用角色/分配保留。服务密码随机生成，私有凭据文件位于仓库外；管理员密码未保存到文件。本轮未创建员工邮箱、未改变组成员，也未连接或修改生产环境。

## 验收边界

脚本只验证服务器端登录和读取，不隐式创建员工邮箱或修改通讯组来测试写入。完全隔离内网不需要访问互联网；Linux 依赖仍需提前离线准备，生产还需用新账号完成连接及隔离业务写入验收。

密码设置依据：[PasswordNeverExpires](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.accountmanagement.authenticableprincipal.passwordneverexpires?view=netframework-4.8)、[RefreshExpiredPassword](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.accountmanagement.authenticableprincipal.refreshexpiredpassword?view=netframework-4.8)。
