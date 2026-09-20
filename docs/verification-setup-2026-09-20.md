# 管理员初始化脚本与组织范围授权调整

本文保留当次版本的验证记录。当前脚本已简化为只输入新账号和密码，最新流程与验证边界见 [两项输入版验证报告](verification-account-only-2026-09-20.md)。

## 用户指定的授权边界

组织范围创建普通员工邮箱、管理所有普通静态通讯组成员；不再要求员工 OU 授权边界或通讯组名单。仍不允许安全组、动态组、账号/邮箱删除或禁用、已有密码重置、组创建/删除、邮箱内容访问、服务器和角色管理。

创建位置与权限范围分开：EXCHANGE_ORGANIZATIONAL_UNIT 可留空，省略 New-Mailbox 的 OrganizationalUnit 参数；生产仍要求明确数据库、DC 和持久状态目录。

## 实现

- `deployment/Initialize-ExchangeAutomation.ps1`：独立 PowerShell 5.1 脚本，自动发现 Exchange/AD、选择邮箱域/数据库、创建专用普通 AD 账号和四个裁剪角色，输出无密码交付文件。
- 不依赖 AD PowerShell/RSAT 模块；使用 Windows .NET 目录接口。不自动安装功能或修改服务器安全设置。
- 账号、角色或分配名称冲突时停止；同名但不等价的范围也停止。过滤条件、RecipientRoot 和 Exclusive 属性完全相同的普通组范围经回读后可复用。角色先裁剪、回读确认，再分配给新账号。
- 所有当前和未来普通通讯组通过固定 RecipientTypeDetails 过滤范围覆盖，不使用人工名单。写范围只做类型隔离。
- 完成后以新账号验证 Exchange 远程登录、所需命令参数及一次查询；报告明确 business_write_verified=false、linux_connectivity_verified=false。
- 部分失败尝试禁用本次新账号，保留失败报告和已创建对象以便核查；不删除或覆盖旧对象，不用管理员角色作为回退。

## 验证证据

- Go `go test -race ./...`：通过，新增生产环境允许空 OU、仍要求数据库/DC/状态目录的用例。
- Python 直连回归 **30/30**：通过，无跳过；新增空 OU 时不传 OrganizationalUnit、只读检查不要求未使用 OU 参数的用例。
- 在测试 Exchange 服务器原生 Windows PowerShell 5.1 中运行 `automation/tests/setup_regression.ps1`：**45/45**，该回归本身实际 AD/RBAC 写入 **0**。覆盖语法、四角色参数组合、角色选择和裁剪、危险参数排除、内置角色不变、真实 EMS 字段投影、普通组范围安全复用、重复对象拒绝、WhatIf 无写入、完整主流程顺序、输出不含密码、授权/登录失败后账号禁用和非成功报告。
- 用现有 `svc_exchange_auto@EXCHLAB.LOCAL` 实际运行初始化脚本的 `Test-ServiceEndpoint` 函数：`Authentication=Kerberos`、`Endpoint=Microsoft.Exchange`、`ReadOnlyCheck=Passed`、`BusinessWriteTest=NotRun`。没有调整现有账号权限。

原生 PowerShell 测试借用了测试环境已有的普通 PowerShell 访问能力；这是开发测试工具的运行方式，不是新应用或生产服务账号的权限需求。业务连接仍为 Exchange 直连。

## 真实管理员初始化与业务写验收

已使用测试环境 `EXLAB\Administrator` 在 Exchange 服务器执行完整初始化，成功账号为 `svc_exa260920060300@exchlab.local`，GUID `2399af9b-a105-4d06-a0c7-4ca17b10328f`。账号为普通启用账号、禁止委派，未加入管理员组；`RemotePowerShellEnabled=true`。四个专用角色、四个 Regular 分配及组范围均经管理员会话回读，验证结果 `Passed`。组成员维护的两个子角色共同绑定同一个范围：`RecipientTypeDetails -eq 'MailUniversalDistributionGroup'`，无 RecipientRoot，非 Exclusive。

从 Linux 控制端使用该新账号完成 Kerberos / Microsoft.Exchange 直连检查：8 个业务命令及所需参数全部可见，只读查询通过，未暴露抽查清单中的邮箱删除/禁用、用户修改、组创建删除、RBAC 管理、邮箱权限及导出命令。

随后用新账号完成隔离业务写验收：

- 创建 `ea260920062753@exchlab.local`，主地址 `ea260920062753@bjwgby.com`，邮箱 GUID `08fd44bb-a529-4274-941c-a8c13438af22`。
- 不带密码重复调用返回 `created=false` 且 GUID 不变。
- 加入普通测试通讯组 `app@bjwgby.com`，独立读取确认成员存在；随后移出并再次读取确认成员关系为空。
- 测试 AD 用户和邮箱按业务规则保留；初始密码未写入证据文件。

因此，本测试环境中的真实 AD 建号、角色条目、组主管绕过参数组合、新账号登录、邮箱创建和普通通讯组成员写入均已验证。初始化脚本自身的报告仍保持 `business_write_verified=false`，因为脚本只做只读登录检查；外部隔离验收的结论为 `business_write_verified=true`。

同一新服务账号随后又通过当前 Go HTTP API 完整端到端验收：无 token 返回 401；缺失通讯组在建号前返回 422；不存在邮箱的离职请求返回 404；创建返回 201 并加入 app/dev 两个普通组；重复入职返回 200、`created=false`、不重复设置密码；显示名冲突返回 409；离职移出两个组，重复离职返回空列表；最后再次入职查询确认邮箱和 AD 用户仍保留且组成员为空。随机 API token 和初始密码均未出现在服务日志中。测试对象为 `api260920063414@bjwgby.com`，邮箱 GUID `acbeecb9-36c4-496f-b37d-bcb36a1ccabd`。

## 安全失败记录与剩余边界

真实联调发现并修复了三项仅靠模拟难以发现的兼容问题：Exchange 管理 Shell 在非交互宿主下受严格模式影响、`DomainController` 与 `BypassSecurityGroupManagerCheck` 位于不同内置角色、EMS 角色分配字段投影与模拟对象不同；另增加了完全相同普通组范围的安全复用。每次失败均停在安全状态：

- `svc_exa260920045108`：账号存在但保持禁用；四个裁剪角色、分配和普通组范围保留。该普通组范围已被成功账号严格回读后复用。
- `svc_exa260920053344`：失败发生在 AD 建号前；仅留下四个未分配角色，没有创建第二个 AD 账号。

这些残留对象没有被自动删除或覆盖。是否清理由管理员另行审核；成功账号不依赖前一个禁用账号，但依赖已复用的普通组管理范围。

不能自动绕过独占管理范围、AD split permissions、密码策略、跨域/多 UPN 后缀或生产网络策略。脚本发现独占范围、多域时提示；不修改企业既有隔离规则。跨域覆盖和大规模性能尚未验收。

操作步骤见 [管理员一页指南](admin-setup.md)。文件尚未提交 Git。
