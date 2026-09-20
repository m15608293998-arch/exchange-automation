# 两项输入、精简与隔离内网说明验证（2026-09-20）

## 当前交付

[初始化脚本](../deployment/Initialize-ExchangeAutomation.ps1) 的普通操作只有两次提示：新服务账号短名称、新密码。员工只有一个邮箱后缀，仍由应用部署配置一次，不在建号时询问；数据库及员工 UPN/OU 也不是建号输入。

当前脚本 SHA-256：`8725250bab8617a2609b80ff5dd14f5bfbe670bca5b5c3db36cdf1e7c3d1f38b`。

精简了不参与服务账号创建的邮箱域/数据库选择、全林域与员工 UPN 后缀枚举、重复的管理命令预检和角色二次内容校验。仍保留已有名称保护、先裁剪角色再授权、分配及组类型范围核对、真实服务登录检查、失败时禁用新账号等关键保护。没有放宽 RBAC，也没有启动 HTTP API 或改动接口认证。

## 当前文件的验证

- 在测试服务器原生 **Windows PowerShell 5.1** 执行 **95/95 回归通过**。AD/RBAC 写入全部模拟，真实目录写入和 Exchange 写入均为 0。
- 覆盖恰好两次提示、只返回完整账号名、拒绝覆盖旧账号、空密码/无效名称、`-WhatIf` 零写入、授权或登录失败禁用账号、固定 8 个业务命令、普通组类型范围和危险参数裁剪。
- 加入根据生产截图整理的 Exchange 2019 CU6 四类根角色和八个业务命令参数数据；当前初始化脚本所需参数均存在，并验证 `Get-Recipient` 缺少非必需 `DomainController` 参数时仍可兼容。
- 新增连接配置实对象检查：`ConnectionUri` 为传入的内网 Exchange 地址；`ShellUri` 为固定 Exchange 协议标识；Kerberos 保留；`ProxyAccessType=NoProxyServer`；不跟随重定向。连接配置对象的构造本身不打开会话。
- AST 检查未发现常见网页探测或在线安装命令。该检查只约束本仓库脚本，不把静态检查等同于整台服务器的网络抓包。
- 使用已有测试服务账号实际执行**当前版本**的 `Test-ServiceEndpoint`，通过 Kerberos 登录测试 Exchange、业务命令/参数检查及只读查询：`ReadOnlyCheck=Passed`、`BusinessWriteTest=NotRun`。真实服务端写入为 0。

回归输出中故意触发的 `preflight`、`assign-application-roles`、`verify-service-login` 报错来自失败路径测试；最终结果为 95 项通过，不是实机建号报错。

## 两项输入版的真实建号

本节使用的是随后精简前的两项输入版，文件 SHA-256 为 `aebf4f697e700a6b07b5b0d5ca0ce959c3708298d6d43fabf275569b8fd9f6a0`，不把它说成当前哈希文件的完整建号验收。

- 在测试 Exchange 服务器执行同一份脚本文件，只代答账号和密码两项提示，没有提供邮箱域、数据库、员工 OU 等参数。
- 新账号：`svc_in260920090157@exchlab.local`。
- 初始化脚本实际输出 `SUCCESS`，完成服务器本地新账号登录检查，并返回完整账号名。
- 随后的开发测试封装在读取交付报告时遇到 `Cannot convert value to type System.String.`，所以**完整封装流程没有通过，报告回读和重复执行保护不记为实机通过**。脚本输出成功与封装读报告错误分开记录，不用“全部成功”概括。
- 独立使用这个新账号及原始小写域后缀，在 Linux 直连真实 Exchange：8 个业务命令及所需参数检查、只读查询通过；`app`、`dev` 短名称解析通过；可用命令清单恰为 8 个业务命令加端点基础命令，无额外业务/管理命令。
- 本轮没有用该新账号再创建员工邮箱或修改组成员；此前版本的真实业务写入证据见 [二次实机复验](verification-setup-recheck-2026-09-20.md)。不把别的账号/版本的业务测试冒充本轮测试。

非密码连接结果保存在开发机 `/tmp/exchange-account-only.MhSlhd/connection-result.json`。新服务账号及其专用角色/分配保留，没有清理旧账号或生产数据。

## 离线边界与迁移

代码中的 `http://schemas.microsoft.com/powershell/Microsoft.Exchange` 是 `WSManConnectionInfo` 的 `ShellUri`，不是要访问的微软网站。实际网络地址是另一参数 `ConnectionUri`，本脚本由本机 Exchange FQDN 生成；登录验证显式禁用代理和重定向。[构造参数说明](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.wsmanconnectioninfo.-ctor?view=powershellsdk-7.4.0)

脚本使用服务器已经安装的 Windows/.NET/Exchange 组件，不下载依赖、不探测互联网；本次测试只连接授权的测试 Exchange。**没有改变测试机公网出口或执行完全断网的端到端部署验收**，也没有把操作系统自身的证书/域策略行为计入已验证范围。

Linux 依赖必须提前打包，内网只执行禁用包索引与在线更新检查的本地 wheel 安装。已明确区分外网构建步骤与内网安装步骤，不能在内网直接执行普通 `pip install -r requirements-direct.txt` 期待下载。

迁移到生产的新地址、服务凭据、域控、员工邮箱/UPN 后缀、数据库、Kerberos Realm/KDC、业务监听地址和本机路径的修改位置，见 [内网迁移配置清单](intranet-migration.md)。完全隔离内网的最终可用性仍需要按清单在目标环境验收。
