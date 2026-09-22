# 生产 Exchange 环境适配记录（2026-09-20）

## 已收到的只读信息

管理员回传的是 [只读采集脚本](../deployment/Get-ExchangeEnvironment.ps1) 的 7 张屏幕截图。截图不包含密码、员工清单或邮件内容。根据截图可确定：

| 项目 | 生产值 |
|---|---|
| Windows | Windows Server 2019 Standard，`10.0.17763` |
| PowerShell / .NET | Windows PowerShell `5.1.17763.316`，64 位；.NET Release `528049` |
| Exchange | Exchange Server 2019 Standard，`15.2.659.4`，ExSetup `15.02.0659.004` |
| Exchange 服务器 | `EXCHANGE.BJWGBY.COM`，Mailbox 角色 |
| AD 域 / 林 / 可写 DC | `BJWGBY.COM` / `BJWGBY.COM` / `EXCHANGE.BJWGBY.COM` |
| 额外 UPN 后缀 | 未配置 |
| 邮箱数据库 | `Mailbox Database 1119980504`，已挂载，非 Recovery，未排除自动预配 |
| 接受域 | `BJWGBY.COM`，Authoritative、Default |
| 默认邮件地址模板 | `SMTP:@bjwgby.com` 形式，员工邮箱域为 `bjwgby.com` |
| PowerShell 前端 | `http://mail.bjwgby.com/powershell`，不要求 SSL，WindowsAuthentication=true，Basic=false |
| 扩展保护 | 截图中前端和后端均为 `None` |
| 依赖服务 | WinRM、W3SVC、MSExchangeADTopology、MSExchangeIS、Netlogon 均为 Running/Automatic |
| 自定义管理范围 | 采集结果为空；未看到既有自定义或独占管理范围 |

截图显示这台 Exchange 同时是域控（DomainRole=5）。本项目不因此授予服务账号域管理员、本机管理员或 Windows PowerShell 权限；初始化脚本仍创建普通域账号并只分配裁剪后的 Exchange RBAC。

## 对代码的影响

- 管理员建号脚本仍只输入新账号名和密码。域、DC 和真实 Exchange FQDN 自动发现，不新增邮箱域、数据库或 OU 提示。
- Kerberos 连接固定使用真实服务器 FQDN `EXCHANGE.BJWGBY.COM`，不默认使用 `mail.bjwgby.com` 别名；截图没有证明别名注册了 HTTP SPN。
- 生产四类内置根角色均唯一存在，读写范围为 Organization；截图中的八个业务命令参数覆盖当前脚本要求。已把这组 CU6 能力作为独立回归数据加入测试。
- 生产没有现有普通通讯组自定义范围，因此第一次成功运行预计会新建一个只匹配 `MailUniversalDistributionGroup` 的范围。脚本不会修改现有范围。
- 当前使用 [本机服务配置模板](../deployment/config.example.json)，不再使用 Linux 环境变量/Kerberos 文件。模板不含服务账号密码或管理员密码。
- 初始化成功报告现在记录实际 Exchange FQDN 和 `AdminDisplayVersion`，方便确认最终执行环境。

2026-09-20 版本初始化脚本 SHA-256 为 `8725250bab8617a2609b80ff5dd14f5bfbe670bca5b5c3db36cdf1e7c3d1f38b`，当时完成 95 项原生 PowerShell 模拟回归及测试 Exchange 只读检查，历史记录可从 Git 恢复。当前验证见 [本机验收](verification/local-2026-09-22.md)。生产截图参数测试仅是相关参数子集验证，不代替生产写入验收；新加入的只读 `Get-DistributionGroup -Filter` 要求仍由建号脚本核对实际父角色。

2026-09-21 再次对照截图：View-Only Recipients 的 `Get-Recipient` 实际包含 `DomainController`，已纠正 README 和测试数据中混用测试账号限制的表述；程序原有按实际能力适配的行为保持兼容。

## 不能从截图证明的事项

- 截图只能证明命令/参数可见，不能证明执行管理员拥有完整的 AD 建号和 RBAC 委派写权限。
- 不能判断是否启用了会阻止 Exchange 创建 AD 安全主体或维护组成员的 AD split permissions，也不能证明对象 ACL 没有额外拒绝。
- 没有生产服务账号，因此尚未验证该账号作为本机 Windows 服务登录、创建邮箱、写入数据库或维护普通通讯组。
- 没有查询员工对象；`upn_suffix=bjwgby.com` 是根据单一 AD 域、无额外 UPN 后缀得出的新员工配置。管理员若另有员工登录命名规范，应在业务验收前指出。
- `http_address` 是 Exchange 本机 Python 服务的监听地址，示例 `0.0.0.0:18082`；生产接入方地址及端口放行由部署时确定。

## 版本风险

此前“测试和生产软件版本相同”的假设不成立：测试环境是 Exchange 2019 `15.2.1748.10`，生产截图是 `15.2.659.4`。微软构建表将后者标识为 **Exchange 2019 CU6（2020-06-16）**；当前官方页面也明确 Exchange 2019 已结束支持。此处只做当前命令参数兼容适配，不能把应用兼容测试解释为服务器安全或厂商支持状态合格。

在不改变生产服务器版本的前提下，后续必须分两步验收：先运行正式初始化脚本并确认新账号只读登录通过，再使用隔离员工和普通测试通讯组做创建/加组/离组验收。升级 Exchange 属于管理员独立变更，本项目不会自动升级、下载补丁或修改服务器安全设置。
