# 管理员建号脚本二次实机复验（2026-09-20）

本文保留当次版本的验证记录，包含旧的邮箱域/数据库选择过程。当前脚本已改为只输入新账号和密码，不再接受那些业务参数；最新流程与版本边界见 [两项输入版验证报告](verification-account-only-2026-09-20.md)。

后续生产采集已经证明“内网软件版本与测试环境相同”的早期假设不成立：生产为 Exchange 2019 `15.2.659.4`，本报告测试机为 `15.2.1748.10`。生产适配结论以 [生产环境记录](production-environment-2026-09-20.md) 为准；下文关于版本相同的文字只保留为当时记录。

## 结论

当前脚本能够在测试 Exchange 上自动发现环境、创建普通 AD 服务账号并完成业务授权；新账号已在 Linux 上实际完成“原先不存在的员工 AD 用户及邮箱创建 → 加入 app/dev → 移出 app/dev → 幂等重试”。未发现本次业务所需权限不足。

首次复验发现脚本交付的 `EXCHANGE_USERNAME` 使用小写 AD 域后缀，与本机配置中的大写 Kerberos Realm 不匹配。改用 `账号@EXCHLAB.LOCAL` 后，同一账号和密码通过连接及全部业务验收。此问题属于登录名处理，不是 AD 或 RBAC 授权不足。用户随后要求支持大小写登录，现已在直连程序认证前统一处理 AD Realm；不再要求管理员修改脚本输出或手工改写登录名。下方保留首次复验的原始结果，不将修复后的行为混入原始记录。

用户说明内网 Windows 和软件版本与测试环境相同，因此本次结果支持相同版本的运行兼容性；尚未接入内网，不能替代内网 DNS、网络、密码策略、执行策略和 Exchange 组织权限配置的验收。

## 本次验证对象

- 脚本：`deployment/Initialize-ExchangeAutomation.ps1`。
- 实际复制到 Windows 执行的文件 SHA-256：`8cf6465a66d5b481a971fcf5bea288d578eb4c12a9fd2f8612f89c41668229e6`；本地与远端一致。
- 操作系统：Microsoft Windows Server 2019 Datacenter，`10.0.17763`。
- Windows PowerShell：`5.1.17763.316`，64 位 Desktop。
- Exchange：管理版本 `15.2 (Build 1748.10)`，ExSetup.exe 文件版本 `15.02.1748.010`。
- .NET Framework Release：`528049`；当前 PowerShell 执行策略：`RemoteSigned`。
- 测试服务器：`EXCHLAB.exchlab.local`；自动发现同域可写 DC：`EXCHLAB.exchlab.local`。

交付脚本没有写死以上测试服务器、域名、IP、数据库或通讯组；不下载组件、不要求安装 AD PowerShell/RSAT 模块。开发用远程测试工具不属于交付脚本。

## 自动发现与真实建号

真实建号调用只指定新服务账号名称并关闭确认提示，没有预填 DC、邮箱域、数据库、员工 UPN 后缀、OU、密码参数或输出目录：

```powershell
.\Initialize-ExchangeAutomation.ps1 -ServiceAccountName svc_rv260920080601 -Confirm:$false
```

脚本自动找到 AD 域、DC、Exchange 端点和唯一可用数据库；发现两个邮箱域后，实际经过 `Read-Host` 序号选择流程；新服务密码经过 `Read-Host -AsSecureString` 输入流程。测试宿主代答提示，执行的是同一份未改写的脚本文件。

结果：

- 新账号：`svc_rv260920080601@exchlab.local`。
- GUID：`98a1979c-e8ad-47a1-8ae2-06ca58ae617f`。
- 脚本实际输出 `SUCCESS`，新账号完成服务器端 Exchange 登录、8 个业务命令参数核对和只读查询。
- 输出目录：`C:\ProgramData\ExchangeAutomation-Recheck-f675c1911624\exchange-handoff-e1a7f082e8ec4c86b5e7adea16ea3035`。
- 独立 Exchange 管理连接回读：账号启用、`RemotePowerShellEnabled=true`，有效 Regular 分配恰好 4 个；没有额外有效角色分配，显式 AD 组成员查询为空。
- 创建角色写范围为 Organization；成员维护两个角色均绑定同一个普通通讯组类型范围，无 RecipientRoot，非 Exclusive。复用已存在的等价范围，不依赖范围名称中的旧账号本身。
- 4 个内置父角色的全部命令及参数摘要在建号前后完全相同：`9d298c291eaba6cb83c375c72c98d9cc0bc1e774b4d037573c2493383a9f57cc`。

`-WhatIf` 另行实测：指定邮箱域和数据库用于无交互预览，其余环境自动发现；前后没有新账号、角色、分配、范围或交付文件。原生 Windows PowerShell 模拟回归重新执行 **45/45 通过**，该模拟回归真实 AD/RBAC 写入为 0。

## 新账号的真实业务验收

仅将 Linux 登录名 Realm 改为大写，未补加账号权限或修改服务器配置。

| 验收项 | 实际结果 |
|---|---|
| Linux Kerberos 直连 Microsoft.Exchange | 8 个业务命令及参数检查、查询通过，不使用凭据委派 |
| 新员工事先不存在 | Get-User、Get-Mailbox 查询均不存在 |
| 创建员工 AD 用户和普通邮箱，OU 留空 | 成功 |
| 不带初始密码重复创建 | `created=false`，邮箱 GUID 不变 |
| 传入 `app`、`dev` 短名称 | 解析为现有两个普通通讯组，无需调用方拼邮箱后缀 |
| 加入 app、dev | 两组均 `added=true`，另行读取确认 |
| 移出 app、dev | 两组均 `removed=true`，另行读取确认组列表为空 |
| 重复移出 | 两组均 `removed=false`，无错误 |
| 离组后重新查询邮箱 | 邮箱和 AD 用户保留，GUID 不变 |
| 服务端可用命令清单 | 只有 8 个业务命令及端点基础命令，抽查的删除邮箱、改用户、组创建删除、角色管理、邮箱内容/权限命令均未暴露 |

测试员工：`rv260920081547@exchlab.local`，主邮箱 `rv260920081547@bjwgby.com`，GUID `406e2742-8fe4-4b8c-a5cf-f87da2d2a489`。app/dev 的组主管仍是原管理员，不是新服务账号，业务通过不是靠逐组加主管实现。

本次新增的服务账号、4 个专用角色/分配和测试员工邮箱保留；本次测试添加的 app/dev 成员关系已移除。未删除旧对象，也未重启 HTTP API 或更改接口认证。

## 发现的交付问题：Kerberos Realm 大小写

同一账号的两次只读连接结果：

```text
svc_rv260920080601@exchlab.local
  Krb5Error: Cannot find KDC for realm "exchlab.local"

svc_rv260920080601@EXCHLAB.LOCAL
  check_connection: passed
```

当前控制机 `krb5.conf` 配置的是 `EXCHLAB.LOCAL`；Linux 库不会把显式传入的小写 Realm 自动当作大写 Realm。Windows 的服务器端登录检查不能发现这个控制端差异。MIT 文档说明 Realm 名区分大小写，惯例使用大写；AD 域使用大写 Realm 的形式也有微软说明。[MIT Kerberos 协议说明](https://kerberos.org/software/tutorial.html)、[Microsoft Kerberos Realm 说明](https://learn.microsoft.com/en-us/azure/azure-netapp-files/kerberos)。

该问题现由 `automation/direct/exchange_psrp.py` 的连接层处理：对于 Kerberos 的普通 `账号@AD域` 登录名，仅将 `@` 后面的 Realm 规范为大写。两种凭据来源共用这一步处理，用户名本体和密码保留原样；不修改凭据文件、脚本交付文件、员工 UPN、SMTP 邮箱域或 AD 权限，不增加认证重试或协议降级。Linux 的 Realm/KDC 配置仍必须正确。

### 大小写兼容修复后的实机验收

同日使用同一个新服务账号及原密码，对修改后的实际 Python worker 再次进行只读验证，以下全部通过：

| 登录名/输入方式 | 结果 |
|---|---|
| 原始凭据文件中的 `svc_rv260920080601@exchlab.local` | 8 个业务命令参数及查询通过；凭据文件字节未变 |
| 标准输入 JSON：`svc_rv260920080601@EXCHLAB.LOCAL` | 通过 |
| 标准输入 JSON：`svc_rv260920080601@ExChLaB.LoCaL` | 通过 |
| 标准输入 JSON：`SVC_RV260920080601@exchlab.local` | 通过，覆盖用户名本体大写 |
| 标准输入 JSON：`SvC_Rv260920080601@ExChLaB.LoCaL` | 通过，覆盖用户名及域名混合大小写 |
| 环境变量配置、混合大小写域名，执行 `--check` | 通过 |
| 使用原始小写凭据文件查询 `app`、`dev` | 两个组均正确解析 |

前五项通过实际 worker 子进程及 JSON 标准输入执行，与 Go 调用 worker 的边界一致；没有启动 HTTP API。此轮真实服务器写入为 0，没有新增服务账号、重设密码、改动角色/组或修改管理员脚本。

Python 回归 **36/36 通过，无跳过**；新增域后缀三种大小写、用户名/密码保留、不猜测其他登录名格式、NTLM 不转换、环境变量和凭据文件一致性等用例。`go test -race ./...` 全部通过（使用可写临时构建缓存）；`git diff --check` 通过。

本轮 Python worker SHA-256：`d0c4ff03e7138feb0ad3521fb13c58cca94b1bedbd837f5adb3c725c91cc979d`。非密码实测结果保存于 `/tmp/exchange-realm-case.8a7OmR/result.json`。管理员初始化脚本 SHA-256 保持本报告开头的值不变，原脚本输出的小写账号现在可直接交给新版本直连程序使用。

## 内网执行需要什么

管理员将单个脚本复制到 Exchange 服务器本地，用具备 **AD 建号权限和 Exchange RBAC 角色管理权限** 的身份打开 64 位 Windows PowerShell 5.1 / Exchange Management Shell，执行并按提示设置服务账号密码、选择邮箱域/数据库即可。成功后交付账号密码、`setup-report.json` 和 `application.env.example`。不需要新建员工 OU，不需要整理通讯组名单，不需要为服务账号授予 Windows 通用远程执行权限。

版本相同之外，仍有以下环境边界：

- 当前初始化脚本验证的是服务器真实 FQDN 的 `http://.../PowerShell/` + Kerberos。内网如只允许 HTTPS 或禁用该端点，需按现有组织配置调整，不能声称当前默认路径已经覆盖；标准 Exchange 连接使用该端点，不要求应用访问普通 WinRM 5985。[Microsoft Exchange 远程连接说明](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-servers-using-remote-powershell?view=exchange-ps)。
- 管理员身份需要上述目录和 RBAC 权限；Exchange 的独占范围、AD split permissions、不同对象 ACL 不会因版本相同而自动消失。当前实测为单域、一个数据库、两个普通通讯组，不是逐个验证内网所有对象。
- Linux 仍需正确的内网 DNS/KDC、网络可达和时间同步，由应用维护方配置，不要求 Exchange 管理员安装 Linux/Python/Ansible。
- 脚本文件须符合内网执行策略。若从外网复制后附带下载标记，`RemoteSigned` 可能要求先核实文件来源并解除该文件的阻止；`AllSigned` 则需组织认可的签名。本次没有更改执行策略，也没有使用 Bypass。[Microsoft PowerShell 执行策略](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies)。

## 证据边界

原始非密码结果保存在控制机 `/tmp/exchange-setup-recheck.wgRNFr/` 的 `inspect-result.json`、`preview-result.json`、`exchange-admin-audit.json`、`business-result.json`；服务密码另存在私有文件，不包含在本报告中。

最初测试工具在脚本已经输出成功后，对普通 Windows 远程会话的额外回读出现超时/HTTP 400；再次回取文件时出现服务器找不到 ShellId（WSManFault `2150858843`）。因此本次没有独立取回磁盘上的交付报告，不将“报告文件回读”列为通过；上文的成功输出和输出路径来自实际执行流。随后通过独立的 Exchange 端点完成账号、有效角色、父角色摘要和业务核验。这不证明普通 Windows WinRM 通道无问题，也不影响已完成的 Exchange 直连业务结果。

重复执行保护已由代码检查和模拟回归覆盖，本次因上述工具回读中断，没有完成原计划的同名账号整脚本二次执行；不将该项列为真实通过。
