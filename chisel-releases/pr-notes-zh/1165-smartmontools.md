# PR #1165 — smartmontools

<https://github.com/canonical/chisel-releases/pull/1165>

分支 `feat-26.04-smartmontools`，目标分支 `ubuntu-26.04`。

这是这批包里 SDF 最复杂的一个（6 个切片），因为它涉及一个必须复现的 postinst
动作，还有一整套通知脚本链。

## 1. 这个包是干什么的

`smartmontools` 用来监控硬盘/SSD 的 **S.M.A.R.T.**
（Self-Monitoring, Analysis and Reporting Technology）数据 —— 磁盘固件自己统计的
健康指标：重映射扇区数、通电小时数、温度、坏块、写入量等等。用来在磁盘彻底挂掉
之前预警。

两个主程序：

| 程序 | 作用 |
|---|---|
| `smartctl` | 命令行工具。一次性读取/打印磁盘健康信息、启动自检、开关 SMART |
| `smartd` | 守护进程。按 `/etc/smartd.conf` 配置周期性轮询所有磁盘，发现异常就告警 |

常用法：

```bash
smartctl -a /dev/sda          # 打印全部信息
smartctl -H /dev/sda          # 只看总体健康结论（PASSED/FAILED）
smartctl -t short /dev/sda    # 启动短自检
smartctl -P showall           # 打印驱动器预设数据库
```

### 驱动器预设数据库（drivedb）

不同厂商的磁盘对 SMART 属性编号的解释不一样 —— 同样是 attribute 1，
某些型号是"原始读错误率"，另一些型号语义完全不同。`smartmontools` 维护一个
**drivedb**（`drivedb.h`，约 260 KB，792 条记录），按型号正则匹配后套用正确的
属性名和解读方式。

`smartctl` 二进制里编译了一份内置数据库，同时会**优先读外部文件**，这样不升级
软件也能通过更新数据库支持新型号磁盘。

### 告警脚本链

`smartd` 发现问题时不是自己发邮件，而是执行一个脚本。默认链路是：

```
smartd 发现异常
  └─► /usr/share/smartmontools/smartd_warning.sh   把信息格式化成邮件正文
        ├─► 调 $SMARTD_MAILER（默认 mail 命令）发出去
        └─► 或者跑 /etc/smartmontools/smartd_warning.d/ 里的插件（地址写 @名字）

而 Debian 默认的 /etc/smartd.conf 里配的是：
  DEVICESCAN ... -M exec /usr/share/smartmontools/smartd-runner
  └─► smartd-runner 就一行：run-parts /etc/smartmontools/run.d
        └─► 跑 run.d 里所有脚本（deb 自带一个 10mail）
```

## 2. 切片设计

```yaml
package: smartmontools

essential:
  smartmontools_copyright:

slices:
  bins:            smartctl + smartd
  config:          /etc/smartd.conf + /etc/default/smartmontools
  drivedb:         驱动器预设数据库
  scripts:         告警通知脚本
  services:        systemd unit
  copyright:
```

### deb 里有什么，怎么分的

```
/etc/default/smartmontools                          → config
/etc/init.d/smartmontools                           ✗ 丢弃（sysvinit）
/etc/smartd.conf                                    → config
/etc/smartmontools/run.d/10mail                     ✗ 丢弃（需要 mail 命令）
/etc/smartmontools/run.d/            （目录）        → scripts
/etc/smartmontools/smartd_warning.d/ （目录）        → scripts
/usr/lib/systemd/system/smartmontools.service       → services
/usr/sbin/smartctl                                  → bins
/usr/sbin/smartd                                    → bins
/usr/sbin/update-smart-drivedb                      ✗ 丢弃（要联网+可写）
/usr/share/bug/smartmontools/presubj                ✗ 丢弃（reportbug 元数据）
/usr/share/doc/**                                   ✗ 只留 copyright
/usr/share/lintian/overrides/*                      ✗ 打包元数据
/usr/share/man/**                                   ✗ 手册
/usr/share/smartmontools/drivedb.h                  → 见下（用 copy: 换了位置）
/usr/share/smartmontools/smartd-runner               → scripts
/usr/share/smartmontools/smartd_warning.sh           → scripts
```

### 最关键的设计点：用 `copy:` 复现 postinst

deb 的 postinst 里有这么一段：

```sh
if [ -x "$(command -v update-smart-drivedb)" ]; then
    update-smart-drivedb --install
else
    cp -f /usr/share/smartmontools/drivedb.h /var/lib/smartmontools/drivedb/
fi
```

也就是说**数据库被装到 `/var/lib/smartmontools/drivedb/drivedb.h`**，
`/usr/share/smartmontools/drivedb.h` 只是打包时的模板。

我 `strings` 了两个二进制来确认它们到底读哪里：

```
$ strings /usr/sbin/smartctl | grep -E '^/(etc|var|usr)'
/etc/smart_drivedb.h
/var/lib/smartmontools/drivedb/drivedb.h
```

**根本没有 `/usr/share/smartmontools/drivedb.h`**。所以如果我照搬 deb 的路径去切，
文件是进了 rootfs，但程序永远读不到 —— 白占 260 KB。

Chisel 不跑 maintainer script，所以我用 `copy:` 入口选项来复现这个拷贝：

```yaml
  drivedb:
    hint: Drive presets database
    contents:
      /var/lib/smartmontools/drivedb/drivedb.h:
        copy: /usr/share/smartmontools/drivedb.h
```

`copy:` 的语义是"从 deb 里的这个源路径取内容，放到声明的目标路径"。
所以只需要写目标路径这一条，源路径不用另外声明，也不会有重复副本。

切片名我用了 `drivedb` 而不是 `data`。理由：这份数据落在 `/var/` 下，
叫 `data` 会让 reviewer 疑惑（约定里 `data` 是 `/usr/share` 的静态数据，
`var` 是 `/var` 下的东西），但它本质又是静态数据库不是运行时状态。
用功能名 `drivedb` 最不容易误解，并配了注释解释来龙去脉。

`bins` 的 essential 里写了 `smartmontools_drivedb`：两个二进制启动时都会无条件
尝试读这份数据库，装上它才能正确解读各厂商磁盘的属性。

### `scripts` 切片和它的 shell 依赖

```yaml
  scripts:
    hint: Warning notification handlers
    essential:
      base-files_bin:
      coreutils_uname:
      dash_bins:
      debianutils_run-parts:
      sed_bins:
    contents:
      /etc/smartmontools/run.d/:
      /etc/smartmontools/smartd_warning.d/:
      /usr/share/smartmontools/smartd-runner:
      /usr/share/smartmontools/smartd_warning.sh:
```

这几个依赖不在 deb 的 `Depends:` 里（因为 dash/coreutils/sed 在 Debian 里是
`Essential: yes`，不需要显式依赖），但 chisel rootfs 里什么都没有，必须自己列：

- `base-files_bin` + `dash_bins` —— 两个脚本的 shebang 都是 `#!/bin/sh`。
  `base-files_bin` 提供 `/bin` → `usr/bin` 的符号链接，`dash_bins` 提供
  `/usr/bin/sh`。这个组合是从 `debianutils.yaml` 里学的，它所有 shell 脚本切片
  都是这么写的。
- `debianutils_run-parts` —— `smartd-runner` 的全部内容就是
  `run-parts --report --lsbsysinit -- /etc/smartmontools/run.d`。
- `sed_bins` —— `smartd_warning.sh` 里有一处**不能省**的 sed：
  ```sh
  esc=`echo "$fullmessage" | sed -n -e '/^~/p' ...`
  ```
  这是安全检查（防止邮件正文里的 `~` 被 `mail` 命令当成转义指令）。脚本开头是
  `set -e`，管道最后一个命令失败会导致赋值失败进而整个脚本退出。所以 sed 缺了
  脚本直接挂。
- `coreutils_uname` —— 脚本用这个链条取主机名：
  ```sh
  for cmd in 'hostname' 'uname -n' 'echo "[Unknown]"'; do ...
  ```
  `hostname` 包没被切片，所以实际走 `uname -n`。缺了会退化成 `[Unknown]`，
  告警邮件里主机名就没了 —— 属于真实的功能降级，所以我加上了。

**丢弃 `run.d/10mail`**：它第一件事就是
`if ! [ -x /usr/bin/mail ]; then ... exit 1`。`/usr/bin/mail` 来自
`bsd-mailx` 或 `mailutils`，chisel-releases 里都没有。留着它只会让
`run-parts` 报错，反而不如让 `run.d` 空着（`run-parts` 空目录返回 0）。
但目录本身要切进来，因为它是用户放自己脚本的挂载点。

### `config` 依赖 `scripts`

`/etc/smartd.conf` 里唯一的生效行是：

```
DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner
```

它引用了 `smartd-runner`。所以 `config` 的 essential 写 `smartmontools_scripts`，
避免出现"配置文件指向一个不存在的脚本"这种半残状态。

（我实测过 `smartd` 在解析配置时**不**校验 `-M exec` 的路径是否存在，只有真的
要告警时才执行。所以不加这个依赖也不会立刻炸，但那样就是埋雷。）

### 其他丢弃项

- **`update-smart-drivedb`** —— 从网上下载新数据库，需要可写 `/usr` +
  `curl`/`wget` + `gpg` 验签。和 pciutils 的 `update-pciids` 一个道理。
- **`/etc/init.d/smartmontools`** —— sysvinit 脚本。虽然 `sysvinit-utils` 恰好被
  切了（提供 `/usr/lib/lsb/init-functions`），但它还需要 `start-stop-daemon` 和
  `update-rc.d` 建的运行级别链接，而且 systemd unit 已经覆盖这个功能。
- **`/usr/share/bug/smartmontools/presubj`** —— Debian reportbug 用的元数据。

## 3. spread 测试逐行解释

文件：`tests/spread/integration/smartmontools/task.yaml`

测试分四段，每段一个**全新 rootfs**，对应四个功能切片。

### 第一段：`bins`（含 `drivedb`）

```bash
rootfs="$(install-slices smartmontools_bins)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
```
切 rootfs。造一个假的 `/dev/null` —— 切片里没有 `/dev`，而后面几个命令
（包括 shell 里的 `2>/dev/null`）需要它。

```bash
out="$(chroot "${rootfs}" /usr/sbin/smartctl --version)"
echo "${out}" | grep -Fq "smartctl 7.5"
out="$(chroot "${rootfs}" /usr/sbin/smartctl -h)"
echo "${out}" | grep -Fq "Usage: smartctl"
```
冒烟：能启动、版本对、用法能打印。

```bash
out="$(chroot "${rootfs}" /usr/sbin/smartctl -P showall)"
echo "${out}" | grep -Eq "Entries read from file\(s\): +[1-9][0-9]*"
```
**这一条是整个测试里最关键的断言**，它验证 `drivedb` 切片（也就是那个 `copy:`）
真的起作用了。

`-P showall` 打印所有驱动器预设，末尾有两行统计：

```
Total number of entries  :  792
Entries read from file(s):  792
```

**`Entries read from file(s)` 只统计从外部文件解析出来的条目，不含编译进二进制的
那份内置库**。我实测验证过这一点：

- 把外部文件删掉：`-P showall` 仍然输出内容（内置库），但 `read from file(s)` 为 0
- 放一个只有一条记录的假文件：显示 `Entries read from file(s): 1`
- 放一个语法错误的文件：直接报 `drivedb.h(2): Syntax error, invalid char 'c'`

所以 `[1-9][0-9]*` 这个正则（要求非零）证明了：文件落在了正确的路径上、
内容完整、语法能被解析。如果我当初照搬 `/usr/share` 路径，这条断言就会失败。

```bash
chroot "${rootfs}" /usr/sbin/smartctl --scan
chroot "${rootfs}" /usr/sbin/smartctl --scan-open
```
设备枚举。chroot 里没有磁盘，两条命令输出为空但**必须返回 0**
（"没有磁盘"不是错误）。这验证了设备扫描代码路径不会崩。

```bash
out="$(chroot "${rootfs}" /usr/sbin/smartctl -i /dev/null 2>&1 || true)"
echo "${out}" | grep -Fiq "unable to detect device type"
```
拿 `/dev/null` 当磁盘，`smartctl` 的设备类型探测层会拒绝它并**返回 1**，
所以要 `|| true`。这是一个负向测试：证明设备探测逻辑在跑，而不是把任何东西都
当磁盘处理。

```bash
printf '# no directives\n' > "${rootfs}/test.conf"
rc=0
out="$(chroot "${rootfs}" /usr/sbin/smartd -c /test.conf -q onecheck 2>&1)" || rc=$?
test "${rc}" -eq 17
echo "${out}" | grep -Fq "Opened configuration file /test.conf"
echo "${out}" | grep -Fiq "parsed but has no entries"
```
测 `smartd`。`-q onecheck` 让它只跑一轮检查就退出（不进入守护循环，
不会挂住测试）。`-c` 指定配置文件。

`smartd` 在没有可监控磁盘时**退出码是 17**，所以不能直接让它裸跑（`set -e` 会
终止），要用 `|| rc=$?` 接住再断言 `-eq 17`。精确断言退出码而不是 `|| true`，
是为了区分"预期的没有磁盘"和"真的崩了"。

两条 grep 分别验证：配置文件被打开了、被正确解析为空配置。

> 为什么不用 `sleep` 等守护进程？mason 的规则明确禁止：
> "No magic sleeps or unbounded retry loops"。`-q onecheck` 是有界的、确定性的。

### 第二段：`config`

```bash
rootfs="$(install-slices smartmontools_bins smartmontools_config)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"

test -s "${rootfs}/etc/default/smartmontools"
rc=0
out="$(chroot "${rootfs}" /usr/sbin/smartd -q onecheck 2>&1)" || rc=$?
test "${rc}" -eq 17
echo "${out}" | grep -Fq "Opened configuration file /etc/smartd.conf"
echo "${out}" | grep -Fq "found DEVICESCAN"
```
这次**不带 `-c`**，让 `smartd` 走默认路径。断言它打开的是
`/etc/smartd.conf` —— 也就是我切进来的那个文件 —— 并且解析出了 `DEVICESCAN`
指令。这证明 `config` 切片提供的配置是 `smartd` 默认会用的那份，
而不是躺在那里没人管。

注意这里必须同时装 `bins`，因为 `config` 切片的 essential 只写了 `scripts`
（配置文件本身不"依赖"二进制）。

### 第三段：`scripts`

```bash
rootfs="$(install-slices smartmontools_scripts)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
```
只装 scripts 切片。它的 essential 会把 dash/sed/uname/run-parts/base-files 带进来
—— 如果我漏了任何一个，下面的脚本就跑不起来。这是独立 rootfs 的价值。

```bash
chroot "${rootfs}" /usr/share/smartmontools/smartd-runner
```
空 `run.d` 目录上跑 `smartd-runner`，必须返回 0。这同时验证了
`#!/bin/sh` 能解析（`base-files_bin` + `dash_bins` 生效）和 `run-parts` 存在。

```bash
printf '#!/bin/sh\necho ran > /marker-runner\n' \
  > "${rootfs}/etc/smartmontools/run.d/50chisel"
chmod 755 "${rootfs}/etc/smartmontools/run.d/50chisel"
chroot "${rootfs}" /usr/share/smartmontools/smartd-runner
grep -Fxq "ran" "${rootfs}/marker-runner"
```
往 `run.d` 里丢一个会写标记文件的脚本，再跑一次 `smartd-runner`，
然后**检查标记文件真的被写出来了**。这证明整条
`smartd-runner → run-parts → run.d/*` 链路是通的，也证明 `run.d` 目录切进来是
有用的（用户可以往里放自己的告警脚本）。

文件名用 `50chisel` 而不是 `50-chisel.sh`：`run-parts --lsbsysinit` 要求文件名
只含字母数字和 `-`/`_`，带点的会被跳过。

```bash
out="$(SMARTD_ADDRESS=root SMARTD_MESSAGE="chisel test message" \
  SMARTD_FAILTYPE=EmailTest SMARTD_PREVCNT=0 SMARTD_DEVICEINFO="chisel device" \
  chroot "${rootfs}" /usr/share/smartmontools/smartd_warning.sh --dryrun)"
echo "${out}" | grep -Fq "SMART error (EmailTest) detected on host:"
echo "${out}" | grep -Fq "chisel test message"
echo "${out}" | grep -Fq "chisel device"
```
测告警格式化脚本。`smartd` 是通过环境变量把信息传给它的，我在这里手工模拟：
`SMARTD_ADDRESS`（收件人）、`SMARTD_MESSAGE`（错误描述）、
`SMARTD_FAILTYPE`（失败类型）、`SMARTD_DEVICEINFO`（设备标识）。

`--dryrun` 是脚本自带的选项，**只打印将要执行的 mailer 命令而不真的执行**，
所以不需要 MTA。输出是这样：

```
exec 'mail' -s 'SMART error (EmailTest) detected on host: <主机名>' root <<EOF
This message was generated by the smartd daemon running on:

   host name:  <主机名>
   ...
The following warning/error was logged by the smartd daemon:

chisel test message

Device info:
chisel device
...
```

三条断言验证：邮件主题格式对、错误信息被带进正文、设备信息被带进正文。
主机名能填出来同时说明 `coreutils_uname` 生效了（缺了会是空的）。

环境变量写在 `chroot` 前面而不是用 `env`：chisel rootfs 里没有 `/usr/bin/env`，
但 `chroot` 会把环境传给子进程，所以直接前置赋值就行。（我一开始写 `env` 报
`chroot: failed to run command 'env'`。）

```bash
printf '#!/bin/sh\nprintf "%%s" "$SMARTD_SUBJECT" > /marker-plugin\n' \
  > "${rootfs}/etc/smartmontools/smartd_warning.d/chiselplug"
chmod 755 "${rootfs}/etc/smartmontools/smartd_warning.d/chiselplug"
SMARTD_ADDRESS="@chiselplug" ... \
  chroot "${rootfs}" /usr/share/smartmontools/smartd_warning.sh
grep -Fq "SMART error (EmailTest) detected on host:" "${rootfs}/marker-plugin"
```
测**插件机制**。`smartd_warning.sh` 里有个特殊语法：收件人写成 `@名字` 时，
不发邮件，而是执行 `/etc/smartmontools/smartd_warning.d/名字`。

这次**不用 `--dryrun`**，是真的执行。插件把 `$SMARTD_SUBJECT` 写进标记文件，
然后我从 rootfs 外面读这个文件核对内容。这证明：`smartd_warning.d` 目录切进来
有用、插件调度逻辑正常、环境变量正确传递给了插件。

`printf` 格式串里 `%%s` 是两个百分号 —— 因为外层 `printf` 会吃掉一个。

### 第四段：`services`

```bash
rootfs="$(install-slices smartmontools_services)"
unit="${rootfs}/usr/lib/systemd/system/smartmontools.service"
grep -Fq "ExecStart=/usr/sbin/smartd" "${unit}"
grep -Fq "EnvironmentFile=-/etc/default/smartmontools" "${unit}"
test -x "${rootfs}/usr/sbin/smartd"
test -s "${rootfs}/etc/default/smartmontools"
```
容器里跑不了 systemd（spread 的 LXD 容器有 systemd，但往里注册服务会污染环境，
而且 unit 有 `ConditionVirtualization=no`，在容器里根本不会启动）。所以这里做的是
**引用完整性检查**：

1. unit 文件里 `ExecStart` 指向的二进制，在 rootfs 里真的存在且可执行；
2. unit 文件里 `EnvironmentFile` 指向的配置，在 rootfs 里真的存在且非空。

这正好验证了 `services` 切片的 essential 写对了（`smartmontools_bins` +
`smartmontools_config`）—— 只装 `services` 一个切片，这两个文件是靠依赖被带进来的。
如果我漏写依赖，这里的 `test -x` / `test -s` 就会失败。
