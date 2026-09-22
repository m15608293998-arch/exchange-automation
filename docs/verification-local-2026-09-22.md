# Exchange 本机 Python 服务验收（2026-09-22）

## 范围与环境

仅在外网测试 Exchange `EXCHLAB` / `192.168.6.77` 验证，未连接或修改内网生产环境。Windows Server 2019 x64，Windows PowerShell 5.1；本次安装 Python 3.13.15 x64、pywin32 312、Waitress 3.0.2 和应用 0.2.0。Python 安装包经过官网 SHA-256 及 Windows 有效数字签名核验，安装返回 0，未重启服务器。

Windows 服务 `ExchangeAutomation` 使用现有受限账号 `EXLAB\svc_in260921064205`，业务进程不使用管理员密码。本机 PowerShell 以服务身份连接本机 Exchange 端点。管理员远程会话只用于本次安装、测试编排和独立只读核查，不是业务运行依赖。

测试配置：邮箱/UPN 后缀 `bjwgby.com`，数据库 `Mailbox Database 1512667458`，域控 `EXCHLAB.exchlab.local`。生产模板中的数据库 `Mailbox Database 1119980504` 和域控 `EXCHANGE.BJWGBY.COM` 保持不变。

环境准备的临时脚本未加入仓库。交付项目只保留最小 Windows 服务注册入口；Python、依赖、服务登录权、目录权限由部署人员手动准备。未新增强制 Bearer/JWT 鉴权，生产鉴权由计划中的 Keycloak 接入层负责。

## 真实接口结果

通过测试 Exchange 本机 HTTP 地址 `http://127.0.0.1:18082` 调用，实际受限服务账号执行，不是模拟业务命令。

测试员工：`loc260922162952`；AD 对象 GUID：`a2142019-575f-4e9a-8c13-2d4f8bf422ef`。

| 场景 | HTTP / 结果 | 耗时 |
|---|---|---|
| 组不存在 | 422；未创建请求对应 AD 用户 | 4.16 秒 |
| 新员工缺少密码 | 400；未创建请求对应 AD 用户 | 3.97 秒 |
| 入职，中文显示名、特殊字符密码、短组名 app/dev | 201；创建 AD 和邮箱，加入两个组 | 16.93 秒 |
| 大写账号、大写 APP 重复入职，不传密码 | 200；GUID 不变，不重置密码，两个组均已存在 | 13.80 秒 |
| 大写账号调用离职 | 200；移除 app/dev 两个直接成员关系 | 11.07 秒 |
| 重复离职 | 200；移除列表为空 | 3.67 秒 |

入职请求 ID：`69095c466edb1e3f9552340e47c280f2`；离职请求 ID：`dae12d072d6a87489bebef3956ad782b`。

独立 LDAP 只读回查确认：员工 AD 账号仍启用，邮箱 GUID 和数据库属性仍存在，邮箱地址正确，app/dev 中均已无此成员。两项失败请求的账号 `loc260922162952x`、`loc260922162952y` 不存在。服务账号没有邮箱，密码永不过期，未加入额外 AD 组。

测试员工邮箱保留供核查；本次没有删除账号或邮箱，未修改已有员工对象。

## 停服、回归及边界

- 在真实入职幂等请求执行、`.pending` 已存在时发出停服；业务请求返回 200，约 3.52 秒后服务完成停止，待核查文件已清理。随后启动服务，健康检查通过。
- Linux 和测试机 Windows 的 Python 回归各 13 项通过：同账号并发、幂等、未知结果恢复、旧记录兼容、日志脱敏、输入校验、落盘失败阻止写入、子进程超时/输出限制、停服等待等。
- 实机安装的 API、核心逻辑、Windows 服务入口、注册入口及离职查询脚本 SHA-256 与本地修改后的文件一致。最终服务状态 Running，本机健康检查正常，待核查文件数量为 0。
- 测试机 Windows PowerShell 5.1 回归：建号脚本 128 项、业务脚本 24 项、桥接参数绑定 4 项通过。建号回归中的预期失败分支会输出错误提示，但所有断言通过；这些回归自身不写 AD/Exchange。
- 离职查询改用 `Get-DistributionGroup -Filter "Members -eq '…'"`，实机成功；仍只处理普通静态邮件通讯组，不处理安全组/动态组。查询返回员工直接所属的组，避免逐个扫描全部组成员。DN 单引号转义有回归覆盖。
- 外部机器到测试机 18082 连接超时；本机接口正常。未改变防火墙或网络策略，因此不能声称外部 Postman 已连通。
- 本次证明测试环境下的业务与正常停服流程可执行，不等于已完成生产验收、Keycloak 集成、断电恢复或大规模负载测试。

参考：[Python 3.13.15 官方发布页](https://www.python.org/downloads/release/python-31315/)、[Waitress 参数文档](https://docs.pylonsproject.org/projects/waitress/en/latest/arguments.html)、[Exchange Members 可筛选属性](https://learn.microsoft.com/en-us/powershell/exchange/filter-properties#members)。
