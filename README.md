# Exchange 员工邮箱自动化

服务部署在 Exchange 服务器本机。Python 提供 HTTP API，本机 Windows PowerShell 5.1 连接本机 `Microsoft.Exchange` 端点，并按专用 AD 服务账号的 Exchange RBAC 权限执行操作。

管理员使用 [初始化脚本](deployment/Initialize-ExchangeAutomation.ps1) 创建服务账号和专用角色。Python 服务的离线安装、配置与验收见 [Windows 本机服务部署说明](docs/windows-local-service.md)，生产参数模板见 [Windows 配置模板](deployment/windows-local-config.json.example)。

## 业务边界

- 入职接口只创建普通 `UserMailbox`；调用前 AD 用户应不存在。AD 用户已存在但没有邮箱时返回冲突。
- 通讯组操作只允许普通静态邮件通讯组 `MailUniversalDistributionGroup`。
- 离职接口只移除直接通讯组成员关系，保留 AD 账号、邮箱和地址。
- 服务账号可在组织范围创建员工邮箱并维护普通通讯组成员，不授予本地管理员、域管理员或 RDP 权限。
- 单实例运行；不同员工默认最多同时处理 2 个请求，同一员工的并发请求返回 409。

## 入职接口

```http
POST /api/exchange/users
Content-Type: application/json

{
  "login_name": "slpeng",
  "display_name": "江流",
  "initial_password": "<new-account-password>",
  "groups": ["app", "dev"]
}
```

| 字段 | 说明 |
|---|---|
| `login_name` | 必填，1–20 位 ASCII；首位为字母或数字，其余允许字母、数字、点、下划线和横线 |
| `display_name` | 必填，最多 256 个字符，不允许控制字符 |
| `initial_password` | 新建账号必填；重试已经存在且完全匹配的邮箱时可省略，不会重置已有密码 |
| `groups` | 可省略或为空；最多 100 项；接受 GUID、SMTP、Alias 或唯一名称，短名称如 `app`、`dev` 可直接使用 |

服务先解析并验证全部组，再创建邮箱。返回 201 表示本次创建，返回 200 表示完全匹配的邮箱已经存在。

```json
{
  "login_name": "slpeng",
  "mailbox_id": "<AD-object-guid>",
  "display_name": "江流",
  "user_principal_name": "slpeng@bjwgby.com",
  "primary_smtp_address": "slpeng@bjwgby.com",
  "created": true,
  "password_applied": true,
  "added_groups": ["app@bjwgby.com"],
  "existing_groups": []
}
```

## 通讯组离职接口

```http
POST /api/exchange/users/slpeng/offboard
```

该接口不接受请求体。重复调用返回空的 `removed_groups`。

```json
{
  "login_name": "slpeng",
  "mailbox_id": "<AD-object-guid>",
  "removed_groups": ["app@bjwgby.com"]
}
```

## 运行与恢复

每次业务操作开始前，服务在配置的 `state_directory` 创建 `<login_name>.pending` 文件。操作结果不确定或进程中断时保留该文件，后续对同一员工的请求返回 `OPERATION_STATE_UNKNOWN`。

恢复时根据响应中的 `request_id`、服务日志和 Exchange 实际状态核实操作结果。停止服务后，单独移走已经核实的 `.pending` 文件并留作审计，再启动服务重试。不要批量清空状态目录。

常用状态码：

| 状态码 | 场景 |
|---|---|
| 200 / 201 | 成功 / 本次创建成功 |
| 400 / 415 | 参数或 JSON 错误 / Content-Type 错误 |
| 401 | 配置 `api_token` 后凭据缺失或错误 |
| 404 | 邮箱不存在 |
| 409 | 身份冲突、同员工操作中或存在待核查状态 |
| 422 | 通讯组不存在或类型不允许 |
| 429 | 并发容量已满 |
| 502 / 504 | PowerShell 执行失败或超时；结合 `state_unknown` 判断是否需要核查 |

`GET /healthz` 只表示 Python HTTP 进程存活，不证明 Exchange 会话、数据库和 RBAC 写权限正常。

## 测试

Python 回归：

```powershell
py -3.11 -m unittest discover -s exchange_local\tests -v
```

PowerShell 5.1 桥接回归：

```powershell
.\automation\tests\local_bridge_regression.ps1
```

生产前还必须在安装了 Python 的测试 Exchange 上，以真实受限服务账号完成 Windows 服务启动、隔离员工邮箱创建、加入通讯组和移出通讯组验收。
