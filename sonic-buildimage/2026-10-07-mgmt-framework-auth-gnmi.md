# mgmt-framework 北向接口与 REST 认证

## 1. 背景

SONiC 交换机由「宿主 OS + 几十个 Docker 容器」组成，**所有配置/状态都存在 Redis**（CONFIG_DB / STATE_DB / APPL_DB…）。`mgmt-framework` 容器是设备对外的「北向管理面」，把管理请求翻译成对 Redis 的读写。

---

## 2. mgmt-framework 的三个入口

所有入口最终都汇到一个共享翻译层 **translib**（在 `sonic-mgmt-common` 仓库），translib 负责：REST/gNMI 路径 → YANG 模型 → CVL 校验 → Redis 操作。

| 入口 | 协议 / 载体 |
|---|---|
| **REST**（`rest-server`，Go 写的 RESTCONF 服务器） | HTTPS + HTTP Basic，`/restconf/data/...`|
| **gNMI** | gRPC，由独立的 `sonic-gnmi` 容器提供 |
| **CLI**（`sonic-cli` / klish） | 本机 shell；读走 Redis，写走 REST |

- 读（GET）→ 任何登录用户可读。
- 写（POST/PUT/PATCH/DELETE）→ 只有 admin 组用户可写。

---

## 3. gNMI 是什么、干什么

gNMI = **gRPC Network Management Interface**，OpenConfig 定义的标准，用 gRPC 而非 HTTP。SONiC 把它放在**独立的 `sonic-gnmi`（telemetry）容器**里，和 mgmt-framework 的 REST 是两套进程、两套认证，互不干扰。

四个核心操作：

- **Get**：读配置/状态（对应 REST 的 GET）
- **Set**：改配置（对应 REST 的 PATCH）
- **Capabilities**：宣告支持的 YANG 模型
- **Subscribe**：**流式遥测**——持续订阅某些数据，客户端实时接收变化（这是 gNMI 相对 REST 最大的差异化价值，STREAMING telemetry 的核心）

**gNMI 认证**：由 CONFIG_DB 的 `TELEMETRY|gnmi` 表驱动，`client_auth` 取值 `none` / `cert` / `user`；`cert` 模式要客户端证书（`GNMI_CLIENT_CERT` 表），`user` 模式配合 `user_auth`（TACACS+/本地）。启动脚本 `dockers/docker-sonic-gnmi/gnmi-native.sh` 据此拼 `--allow_no_client_auth` 或 `--client_auth ...` 参数。

---

## 4. REST 认证机制（修复前 vs 修复后）

### 4.1 认证总体流程（这个设计没变，一直是「SSH 假登录」）

`rest-server` 的认证入口是 `rest/server/pamAuth.go` 的 `PAMAuthenAndAuthor`，挂在 HTTP 中间件 `authMiddleware` 上，每个请求都过一遍，三步：

1. 从 HTTP Basic Authorization 头取出用户名/密码；
2. **认证**：用这组凭据去 `ssh.Dial("tcp", "127.0.0.1:22")` 对宿主 sshd 发起一次登录。**握手成功 => 密码正确**（宿主 sshd 自己会做完整的 PAM，包括 shadow / TACACS+ / RADIUS）；
3. **授权**：若是写操作且 `IsAdminGroup(username)==false` → 返回 403 "Not an admin user"。

为什么绕道 SSH：容器里没有宿主的 `/etc/passwd`、`/etc/shadow`、`/etc/tacplus_conf`，所以把「验密码」外包给宿主 sshd。这套设计从 mgmt-framework 第一版（2019-12）就是如此，PAM 代码当年就注释掉了，至今没启用。

### 4.2 为什么「坏了多年」却没人发现：认证默认是关的

- `rest/main/main.go:63`：`client_auth` 参数**默认 `none`**；
- `main.go:92`：只有 `clientAuth == "user"` 才 `AuthEnable = true`；
- `pamAuth.go:155`：`if config == nil || !config.AuthEnable { 放行 }`。

即：默认整条认证是**关闭的**，任何请求直接放行，`PAMAuthenAndAuthor` 是「死代码」。mgmt-framework 多年「正常工作」的本质是**根本没认证任何人**。

**时间线：**

- 2021-01 #6148：`ln -sf /host_etc/passwd /etc/passwd` + group（临时 workaround，注释写着「AAA improvements 合入后删除」）。
- 2021-11 #9375：**移除**这两个符号链接（部分 revert #6148）——因为 debug 镜像在构建期没有 `/host_etc` 挂载，悬空符号链接导致 openssh-client 安装时建组失败。**正确的机制应当是读 `/host_etc`，而不是替换容器自身的 `/etc`**。
- #9375 之后 `IsAdminGroup` 开始坏（容器里查不到 admin），但因认证默认关，无感。
- **2026-04 上游 #26656**：把 `rest-server.sh` 的认证缺省改成 `user`（安全加固「set secure default」）。**这一下把沉睡多年的认证代码激活了**，问题集中爆发。

### 4.4 IsAdminGroup 规则（`pamAuth.go`）

改前逻辑：`os/user.Lookup(username)` → `GroupIds()` → 看是否含 `admin` 主组（读的是**容器**的 `/etc/passwd`）。

改后逻辑：直接解析宿主挂载进来的 `/host_etc/passwd` 和 `/host_etc/group`，规则不变：

- 找出 `admin` 的主 gid（默认 gid=1000）；
- 用户主 gid == admin 主 gid → 是 admin（例：`admin` 用户、或用 `useradd -g admin` 建的用户）；
- 或 用户在 admin 主组的成员列表里（`/host_etc/group` 的 member 字段）→ 是 admin；
- 否则 false → 只读。

同时新增了单元测试 `rest/server/admingroup_test.go` 覆盖主组 / 附加组 / 非成员 / 文件不可读四类场景。

### 4.5 `/host_etc` 是什么

- 由容器启动参数挂载：`rules/docker-sonic-mgmt-framework.mk:35` → `-v /etc:/host_etc:ro`，把宿主的 `/etc` **只读**挂进容器。
- 作用是：让容器代码在不内嵌宿主账号的前提下，仍能按需读取宿主的真实 `/etc/passwd`、`/etc/group`。
- 正解就是去读 `/host_etc`；当年用符号链接顶替容器 `/etc` 是临时做法，后来因 debug 镜像构建失败被撤掉，却没把它改读 `/host_etc`，这才埋下 403。

---

## 5. 上游进展与未解决项（截至 2026-10）

- **401（x/crypto）**：上游 2026-09 在 `e931a06`(#169，grpc CVE 修复) 里「顺带」把 x/crypto 升到 v0.50.0、Go 升到 1.25.9。Canonical 不能抄（Go 版本约束），独立选 v0.48.0。
- **403（IsAdminGroup）**：上游仍用 `os/user`，**至今未修、也无专门 issue**；大家还卡在更前面的 401/sonic-cli 层。
- **six / sonic-cli**：上游仍用 `six.moves`，未修。
- 上游相关议题：
  - sonic-buildimage **#29262**（Open）：`client_auth` 默认改 user 后，on-box sonic-cli 不发凭据，写配置全 401。
  - sonic-buildimage **#29280**（Open）：提议 revert #26656 的默认值。
  - sonic-mgmt-framework **#168**（Open）：长期正解——本地 Unix socket + `SO_PEERCRED`，读 `/host_etc` 判 admin（与本 PR 的 `IsAdminGroup` 修复思路一致）。
