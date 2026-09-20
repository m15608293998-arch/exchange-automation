# Exchange 直连改造验证（2026-09-20）

## 结论

**直连实现已通过本地回归和测试 Exchange 的真实业务联调，并完成独立只读复核。** 这不等于内网生产验收，也不证明所有生产版本、权限范围和负载下均适用。
使用已有 `svc_exchange_auto@EXCHLAB.LOCAL` 服务账号。此次没有使用管理员凭据、创建新的服务账号、授予额外权限或修改服务器配置；仅创建一个业务测试用户及邮箱，并加入/退出既有测试通讯组。

## 改造范围

- 默认 `EXCHANGE_CONNECTION_MODE=direct`，Linux Python/PSRP 直接连接 Exchange `/PowerShell/` 的 `Microsoft.Exchange` 会话。
- 业务判断在控制机完成，远端仅固定 cmdlet + 类型化参数，不使用 AddScript，不需要普通 Microsoft.PowerShell 端点访问权或 Kerberos 委派。
- HTTP Kerberos 强制消息加密；HTTPS 强制验证证书、保留 CBT。NTLM 仅允许显式选择 HTTPS，无自动降级。
- 初始密码使用 PSRP SecureString；Go 经 stdin 传参数，不写请求临时文件、不将密码放入 argv，不向子进程传 API token。
- 保留 GUID/邮箱身份/组类型校验、预检、幂等、写后回读、进程组取消以及原有 API/pending 安全边界。
- 新增 `--check` 只读连接与 RBAC 参数检查。移除默认 Ansible/Windows collection 依赖；旧实现仅显式回退。

## 已验证

- `go test -race ./...` 全部通过，包括新执行器的 stdin 字面值保护、配置安全策略、非零退出、结构化结果、输出限制和超时；原 API/业务/Ansible 回归仍通过。
- `go vet ./...`、`git diff --check` 通过。
- Python 离线回归 28/28 通过，**无跳过**；使用 `/tmp/exchange-automation-python` 的 pypsrp 0.8.1 做真实序列化测试。业务 Exchange 命令被模拟，不发生服务器写入。
- 协议回归验证 `Command.IsScript=false` 和参数保持字面值；真实 SecureString 序列化经过加密并可正确解密还原。
- 无凭据只读 HTTP 探测 `http://exchlab.exchlab.local/PowerShell/`（解析到测试机 192.168.6.77）返回 `401 Access Denied`、`WWW-Authenticate: Kerberos`。这证明端点可达并提供认证挑战，不证明账号已获授权。
- 后续使用已有服务账号运行实际 `--check`：认证、8 个业务命令的参数元数据和只读查询全部通过。会话配置为 `Microsoft.Exchange`，`negotiate_delegate=false`，未使用普通 Windows PowerShell 会话。

## 真实业务联调

日期：2026-09-20；API 测试时间 10:32–10:38（Asia/Shanghai）。从编译后的 Go API → 本地 Python → Exchange `/PowerShell/` 执行完整链路，服务日志确认 `connection_mode=direct`。

环境：Exchange 测试机 `192.168.6.77`，FQDN `exchlab.exchlab.local`，DC `EXCHLAB.exchlab.local`，OU `exchlab.local/Users`，数据库 `Mailbox Database 1512667458`。临时测试服务绑定本机 18082，使用随机 API token，业务超时 10 分钟。

| 检查 | 实际结果 |
|---|---|
| 未提供 API token | 401，未执行业务操作 |
| 请求不存在的组 | 422 GROUP_NOT_FOUND，创建前拒绝，无 partial_result |
| 预检失败后查询该测试邮箱 | 404 USER_NOT_FOUND，确认邮箱尚未创建 |
| 创建 AD 用户与邮箱并加入 app/dev | 201，created=true，password_applied=true，加入两个组 |
| app GUID + app SMTP 重复输入 | 去重，只处理一个 app 组 |
| 显示名包含 `{{ 7 * 7 }}` | 按字面值保存，无模板求值 |
| 无密码重复入职 | 200，created=false，password_applied=false，同一 GUID，两个组均已存在 |
| 同账号但不同显示名 | 409 RECIPIENT_CONFLICT，无写入 |
| 离职通讯组清理 | 200，移出 app/dev，同一邮箱 GUID |
| 再次离职 | 200，removed_groups=[] |
| 清理后不加组查询/确认已有邮箱 | 200，created=false，password_applied=false，原邮箱及显示名保留 |

测试用户：`dx260920023227`；邮箱：`dx260920023227@bjwgby.com`。
AD 对象 GUID：`0eb8549e-04a0-4a87-8ff5-bf016991af9a`。

独立建立新的直连会话，只读执行 Get-Mailbox、Get-User、Get-DistributionGroupMember 再次确认：

- 用户和邮箱都存在，类型 UserMailbox，GUID 与创建时相同。
- UserAccountControl 为 NormalAccount，没有禁用账号。
- app/dev 中该 GUID 的成员数均为 0。
- 没有删除用户或邮箱，没有创建/删除通讯组，没有修改其他成员。

本次小样本耗时：创建并加入两个组 86.708 秒，无密码重复确认 86.001 秒，移出两个组 66.125 秒，空组离职 22.280 秒。多步操作仍需要多次建立会话，不能根据这一小样本承诺生产吞吐。

控制机当时未配置测试域 FQDN 的 DNS 解析，联调仅在测试 Python 进程中将该 FQDN 解析到已知测试 IP；没有修改系统 hosts 或仓库连接策略，URL/Kerberos SPN 仍使用真实 FQDN。生产需要配置正常的内网 DNS，不能将这个临时测试映射当作生产方案。

本机审计日志位于 `/tmp/exchange-direct-live.Y7GOzy/service.log`，其中不含服务账号密码；`state` 目录无待核实 pending 文件，测试服务已释放单实例锁。凭据在仓库外的私有目录中隔离保存（目录 0700、文件 0600），以便用户要求的后续测试使用；未提交到代码库。临时目录不替代生产凭据托管和轮换机制。

## 生产前仍待完成

1. 在目标内网验证实际 DNS/KDC、证书（如使用 HTTPS）、域策略和 Exchange 版本兼容性。
2. 核对生产账号的实际有效 RBAC，尤其普通通讯组的可见范围和可写范围，并验证授权范围外的写入被拒绝。本次没有修改或完整审计服务账号的有效权限，业务成功不能证明它已达到绝对最小权限。
3. 在实际生产规模验证会话配额、组枚举、执行时限和吞吐。仍按组执行成员查询，不承诺已解决大规模性能问题。
4. 按生产 OS/架构/Python ABI 生成完整离线依赖锁定文件、wheelhouse 与交付校验清单。

HTTPS/NTLM 仅完成客户端策略回归，尚无真实环境验证。本次实际验证的是 HTTP + Kerberos 消息加密，不应为本应用贸然开启 NTLM。
本报告的真实业务结果来自新直连独立测试，不引用旧 Ansible 联调作为新连接证据。所有代码变更仍在本地工作区，未提交 Git。
