# gNOI Reboot 流程总结

## 一、背景

SONiC 把各个功能拆成 Docker 容器，例如 `database`、`gnmi`、`sysmgr`、`swss`。容器彼此隔离，没有权力直接重启整台机器。

**gNOI 与 gNMI**（都建立在 gRPC 之上）：

- gNMI（gRPC Network Management Interface，网络管理接口）：读写配置和遥测数据
- gNOI（gRPC Network Operations Interface，网络运维操作接口）：执行运维动作，例如重启、查时间、传文件、装系统镜像

**D-Bus**：Linux 上的进程间通信总线，可以理解成宿主机里的"电话总机"：

- 服务向总机注册名字，例如 `org.SONiC.HostService.reboot`
- 客户端按"服务名、对象路径、接口名、方法名"四项拨号
- 容器通过挂载 `/var/run/dbus` 接入宿主机的总机
- 连上总机后发的第一条消息叫 `Hello`，是握手

**AppArmor**：Linux 强制访问控制机制。每个进程属于一个 profile（规则清单），规定它能访问哪些文件、网络、信号。Docker 默认给容器套 `docker-default` 这份清单。

## 二、Reboot 流程

```
远端管理软件
  │  gNOI System.Reboot 请求（经网络）
  ▼
gnmi 容器（gnoi_system.go 的 Reboot）
  │  ① 认证并校验请求
  │  ② 订阅 Redis 的 Reboot_Response_Channel
  │  ③ 往 Reboot_Request_Channel 发布请求，然后阻塞等回复（有超时）
  ▼
Redis（STATE_DB 里的发布订阅通道，相当于容器间的公告板）
  ▼
sysmgr 容器里的 rebootbackend（订阅 Reboot_Request_Channel）
  │  ④ 检查：格式是否合法、当前有没有重启正在进行、方式是否支持
  │  ⑤ 启动一个后台线程，线程立即返回"成功"
  │  ⑥ 把"成功"发布到 Reboot_Response_Channel   ←  gnmi 在这里收到回复
  │  ⑦ 后台线程随后通过 D-Bus 调用 issue_reboot
  ▼
宿主机上的 sonic-host-server（org.SONiC.HostService.reboot）
  ▼
执行重启
```

关键细节：

- **回复就是往 Redis 发布一条通知。** 通知包含三项：
  - 名字：`Reboot`、`RebootStatus`、`CancelReboot` 三选一，表示在回复哪种请求
  - 状态码：成功是 `SWSS_RC_SUCCESS`，失败有 `SWSS_RC_IN_USE`、`SWSS_RC_INTERNAL` 等
  - JSON 文本：放返回内容 / 错误说明

  `gnmi` 收到后，如果发现状态码不是成功，就转成 gRPC 错误返回给远端，否则返回正常结果。
- **"已受理"不等于"已重启"。** 第 ⑤ 步 `Start` 只是启动后台线程就返回成功，第 ⑥ 步回复随即发出，第 ⑦ 步 D-Bus 调用在后台线程里才发生。所以远端看到成功，只说明"请求合法、没有重复重启、线程已启动"。
- **同一时刻只允许一次重启。** 已有冷重启、关机或热重启进行中时，新请求被回复"不允许"（`SWSS_RC_IN_USE`）


## 三、各方职责边界

### 1. sysmgr 并没有提供 gNOI 的全部接口

`gnmi` 容器自己注册了很多个 gNOI 接口组：`System`、`File`、`OS`、`Containerz`、`Debug`、`Healthz`、`FactoryReset` 等。sysmgr 只参与 `System` 组里的重启相关的接口。

`System` 组里各接口由谁处理：

| 接口 | 谁处理 |
|---|---|
| `Reboot`、`RebootStatus` | 经 Redis 交给 sysmgr 的 `rebootbackend` |
| `CancelReboot` | 也发给 sysmgr，但它直接回复"不支持" |
| `KillProcess` | `gnmi` 处理，通过 D-Bus 请求宿主机停止/重启服务（只支持 SIGTERM） |
| `Time` | `gnmi` 返回当前时间 |
| `SetPackage` | `gnmi` 内部处理 |
| `Ping`、`Traceroute` | 直接返回"未实现" |
| `SwitchControlProcessor` | 返回空结果 |

`File`、`OS`、`Healthz`、`FactoryReset` 等组，`gnmi` 通过 `sonic_service_client/dbus_client.go` 直接调宿主机 D-Bus 服务完成（文件下载、镜像安装、配置保存、重启服务等），不经过 sysmgr。

### 2. rebootbackend 能做的事很窄

- 它自己不执行任何系统操作，只把请求翻译成宿主机的 D-Bus 调用
- 它只会调用两个 D-Bus 方法：`issue_reboot`（发起重启）和 `get_reboot_status`（查询状态）
- 重启方式支持三种：COLD（冷重启，整机所有程序重新启动，转发会中断）、HALT（关机停机）、WARM（热重启，尽量不中断转发）
- 不支持带延迟的重启，带延迟的请求会被拒绝


### 3. 请求来源与别的消费方

sonic-buildimage 仓库中仅有的发送/消费方：

- 往 `Reboot_Request_Channel` 发请求的：只有 `gnmi` 的 `gnoi_system.go`
- 订阅它的：只有 `rebootbackend`

`Reboot` 请求有一个例外分支：先交给 `system.HandleReboot` 处理 DPU 这类子模块的重启，它返回"未实现"时才走本机的 Redis 通道。

局限：只能看仓库里的源码，运行中的交换机上若有厂商私有程序也订阅这个通道，看不到。

## 四、AppArmor 与 D-Bus 审查（PR #20 修的 bug）

### 现象

在 resolute 的 7.0 内核上，gNOI Reboot 请求回复"成功"，但交换机没有重启。

### 原因

1. D-Bus 消息是在用户态的 `dbus-daemon`里转发的，内核看不到。所谓"审查"，是 `dbus-daemon` 取出发送方进程的 AppArmor 标签，再问内核"这个标签能不能发这条消息"。
2. 内核要有对应功能才能回答，可通过 `/sys/kernel/security/apparmor/features/dbus` 目录判断。
3. 内核有这个功能后，`dbus-daemon` 启动时日志会出现 `AppArmor D-Bus mediation is enabled`，开始逐条检查。
4. sysmgr 套的是 `docker-default`，里面没有任何 dbus 规则，所以连第一条 `Hello` 都被拒。
5. `rebootbackend` 的后台线程没有捕获 `DBus::Error`，直接崩溃留下内存转储文件。而第 ⑥ 步的成功回复早已发出，远端根本不知道失败了。这类错误表面上没有任何报错，很难发现。

### 为什么 Debian 版（`202605` 分支）没有这个问题

不是 Debian 上不经过 AppArmor。两个分支的内核启动参数里都有 `apparmor=1 security=apparmor`（`installer/default_platform.conf:602`），所以 Debian 版的容器同样被 AppArmor 限制，只是 D-Bus 消息当时没人检查。

| 分支 | 内核 | D-Bus 审查 |
|---|---|---|
| `202605`（Debian） | 6.12.41 | 按 PR 说法内核没有 `features/dbus`，总机不检查 |
| `202605_resolute_rock` | 7.0.0-1002-sonic | 内核有该功能，总机逐条检查 |

所以是规则缺失这个隐患一直存在，被旧内核盖住了。

### PR 的修法

给 sysmgr 单独写一份 profile `sonic-sysmgr`：

- 以 docker 29.6.1 的 `docker-default` 为基础（对照 `moby/moby` 的 `docker-v29.6.1` 标签验证过，一致）。
- 追加两条 `dbus send` 规则：
  1. 放行 bus 上的 `Hello`、`AddMatch`、`RemoveMatch`（连接握手和订阅信号）；
  2. 放行 reboot 服务的 `issue_reboot` 和 `get_reboot_status`。
- 其余 D-Bus 方法（保存配置、重启服务、`ListNames`）全部拒绝。

这份规则能收得这么窄，是因为 sysmgr 对 D-Bus 的需求本来就只有这几条。对比之下，`gnmi` 容器需要调用的 D-Bus 方法太多，所以用 `apparmor=unconfined`（完全不受限，`rules/docker-gnmi.mk:55`）。

安装方式：`build_debian.sh` 把 `files/apparmor/sonic-*` 复制到镜像的 `/etc/apparmor.d/`，开机时由 `apparmor.service` 在 Docker 启动前加载；`rules/docker-sysmgr.mk` 的 `RUN_OPT` 里加 `--security-opt apparmor=sonic-sysmgr` 选用它。profile 名在三处必须一致：文件里的 `profile` 声明和 `peer=`、`RUN_OPT`。
