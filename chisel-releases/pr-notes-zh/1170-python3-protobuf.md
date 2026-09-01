# PR #1170 — python3-protobuf

<https://github.com/canonical/chisel-releases/pull/1170>

分支 `feat-26.04-python3-protobuf`，目标分支 `ubuntu-26.04`。

## 1. 这个包是干什么的

### Protocol Buffers 是什么

**Protocol Buffers**（简称 protobuf）是 Google 搞的一套**结构化数据序列化**方案，
用来替代 JSON/XML。你先写一个 `.proto` 文件描述数据结构：

```protobuf
message Endpoint {
  string host = 1;
  int32 port = 2;
}
```

然后用编译器 `protoc` 生成各语言的代码，程序里就能：

```python
msg = Endpoint(host="example.com", port=8080)
wire = msg.SerializeToString()      # 序列化成紧凑的二进制
other = Endpoint()
other.ParseFromString(wire)         # 反序列化
```

相比 JSON 的优势：

- **体积小**：字段名不进流，只有字段编号（`= 1`、`= 2`）；整数用 varint 变长编码
- **速度快**：不用解析文本
- **强类型 + 向后兼容**：加字段不破坏老程序（老程序把不认识的字段当
  **unknown fields** 原样保留），删字段也安全（编号不复用即可）

gRPC 的默认序列化格式就是 protobuf。Kubernetes、etcd、Envoy、
以及大量遥测/监控系统的线上协议都用它。

### `python3-protobuf` 提供什么

Python 的 protobuf **运行时库**，包名 `google.protobuf`。注意它**不是**编译器
（`protoc` 在 `protobuf-compiler` 包里）—— 它是 `protoc` 生成的
`*_pb2.py` 文件运行时依赖的那个库。

主要模块：

| 模块 | 作用 |
|---|---|
| `google.protobuf.message` | Message 基类，`SerializeToString` / `ParseFromString` 等 |
| `google.protobuf.descriptor` / `descriptor_pool` | 描述符系统 —— protobuf 的反射机制，记录每个消息有哪些字段、什么类型 |
| `google.protobuf.internal.encoder` / `decoder` | 线格式（wire format）的编解码器 |
| `google.protobuf.json_format` | 消息 ↔ JSON 互转 |
| `google.protobuf.text_format` | 消息 ↔ 人类可读文本格式互转 |
| `google.protobuf.proto_builder` | **运行时**构造消息类型（不需要 `.proto` 文件和 `protoc`） |
| `google.protobuf.*_pb2` | 预生成的 **well-known types** |

**Well-known types** 是 Google 定义的一组通用类型，deb 里以预生成的 `_pb2.py`
形式提供：

- `timestamp_pb2.Timestamp` —— 时间点（秒 + 纳秒）
- `duration_pb2.Duration` —— 时间段
- `struct_pb2.Struct` —— 任意 JSON 式的动态结构
- `empty_pb2.Empty`、`any_pb2.Any`、`wrappers_pb2.*`、`field_mask_pb2.FieldMask`
- `descriptor_pb2.*` —— 描述符本身也是 protobuf 消息（自举）

### 两种实现

protobuf 的 Python 库有两套底层实现：

- **`python`** —— 纯 Python，慢但可移植
- **`upb`** / **`cpp`** —— C 扩展，快

Ubuntu 的 `python3-protobuf` 3.21.12 **只有纯 Python 实现**
（文件列表里没有 `_message` 之类的 `.so`）。这一点我在测试里做了断言。

## 2. 切片设计

```yaml
package: python3-protobuf

essential:
  python3-protobuf_copyright:

slices:
  libs:
    hint: Protocol Buffers Python bindings
    essential:
      python3_standard:
    contents:
      /usr/lib/python3/dist-packages/google/protobuf/**:
      /usr/lib/python3/dist-packages/protobuf-*.egg-info/**:

  copyright:
    contents:
      /usr/share/doc/python3-protobuf/copyright:
```

### 依赖

`Depends: python3:any` —— 就这一个。纯 Python 包，不链接任何 C 库。

我选了 `python3_standard` 而不是 `python3_core`。理由：protobuf 的模块要 import
`struct`、`json`（json_format）、`datetime`（well_known_types）、`re`、
`enum`、`collections.abc`、`copy`、`math`、`numbers`、`typing` 等一大堆标准库。
`python3_core` 只有最小解释器，不够。

`python3_standard` 也是同仓库 `python3-pyftpdlib.yaml` 用的依赖，
有先例可循。

### 路径写法

我查了 26.04 分支上已有的 Python 模块 SDF，约定是：

```yaml
# python3-setuptools.yaml
/usr/lib/python3/dist-packages/_distutils_hack/**:
/usr/lib/python3/dist-packages/setuptools-*.egg-info/**:
/usr/lib/python3/dist-packages/setuptools/**:

# python3-pip.yaml
/usr/lib/python3/dist-packages/pip-*.dist-info/**:
/usr/lib/python3/dist-packages/pip/**:
```

也就是：**模块树用 `<模块>/**`，元数据用 `<名字>-*.egg-info/**`**
（版本号整段用 `*`）。我完全照这个来。

关于 `**` 的宽度：mason 的规则说"通配符要窄，宽泛的 `**` 可能和几百个别的包
的路径撞车"。但这里 `google/protobuf/**` 已经限定到了两级具体目录，
只有这个包会往里面放东西（别的 `google.*` 包放在 `google/` 下的**兄弟**目录，
比如 `google/api_core/`，不冲突）。而且这正是仓库现有约定。

不用一条条列 `*.py` 是因为 protobuf 有四个子目录（`compiler/`、`internal/`、
`pyext/`、`util/`），列出来是 5 条，还得随上游增删维护。`**` 更稳。

### 为什么要带 egg-info

`/usr/lib/python3/dist-packages/protobuf-4.21.12.egg-info/` 里有 `PKG-INFO`、
`top_level.txt` 等，是 Python 的**发行版元数据**。作用：

```python
from importlib.metadata import version
version("protobuf")     # -> "4.21.12"
```

很多库（尤其 gRPC 生态）会在运行时检查 protobuf 版本以决定用哪套 API，
或者用 `pkg_resources` 做依赖校验。缺了 egg-info 这些检查会抛
`PackageNotFoundError`。

注意：`google/protobuf/__init__.py` 里的 `__version__` 是**硬编码**的，
所以 protobuf 自己不需要 egg-info。带上它是为了下游消费者。这也是
`python3-setuptools` / `python3-wheel` / `python3-pip` 的一致做法。

### 一个容易忽略的坑：namespace package

deb 里有 `google/protobuf/__init__.py`，但**没有 `google/__init__.py`**。

这不是打包漏了 —— `google` 是一个**命名空间包**（namespace package）。
Google 家的多个 Python 库（`google.protobuf`、`google.cloud.*`、
`google.api_core` 等）来自不同的发行包，但要共享 `google.` 这个顶级前缀。
如果每个包都带一个 `google/__init__.py`，安装时就会互相覆盖。

解决办法是 **PEP 420 隐式命名空间包**：Python 3.3+ 发现一个目录里没有
`__init__.py` 但有子包时，自动把它当命名空间包处理。egg-info 里的
`namespace_packages.txt` 就是声明这件事的（写着 `google`）。

对切片的影响：我只声明了 `google/protobuf/**`，chisel 提取时会**隐式创建**
父目录 `google/`。这样刚好符合 PEP 420 的预期 —— 目录存在但没有
`__init__.py`。我在测试里把这一点做成了显式断言，防止将来有人"好心"补一个
`google/__init__.py` 进来（那会破坏和其他 google.* 包的共存）。

### maintainer script

`postinst` 只跑 `py3compile`（预编译 `.pyc` 字节码）。chisel 不跑它，
所以 rootfs 里没有 `__pycache__`。这不影响功能 —— Python 会在导入时即时编译，
只是首次导入稍慢一点（而且只读的 `/usr` 下它连缓存都写不了，
直接在内存里编译）。不需要复现。

## 3. spread 测试逐行解释

两个文件：`task.yaml` 和 `test_protobuf.py`。把功能测试单独放一个 Python 文件，
是跟随仓库里 `systemd/test_standard.sh`、`rsyslog/test.conf` 的做法 ——
比在 YAML 里塞一大段 heredoc 干净得多（而且避开了 YAML 缩进和 heredoc 冲突的坑）。

### `task.yaml`

```bash
rootfs="$(install-slices python3-protobuf_libs)"
```
只装这一个切片，`python3_standard` 靠 essential 拉进来。

```bash
test -d "${rootfs}/usr/lib/python3/dist-packages/google/protobuf"
! test -e "${rootfs}/usr/lib/python3/dist-packages/google/__init__.py"
```
**namespace package 断言**。正向：`google/protobuf` 目录存在。
反向：**`google/__init__.py` 必须不存在**。

第二条是有意义的回归保护：如果将来有人给切片加了 `google/__init__.py`
（或者上游 deb 开始提供它），`google` 就变成普通包，安装其他
`google.*` 库时会冲突。这条断言会立刻发现。

```bash
chroot "${rootfs}" /usr/bin/python3 -c \
  'import google.protobuf; print(google.protobuf.__version__)' | grep -Fq "4.21"
```
最基本的导入 + 版本。注意 deb 包版本是 `3.21.12` 但库的 `__version__` 是
`4.21.12` —— protobuf 的版本号体系换过一次（Python 库版本和 C++ 库版本对齐），
Debian 保留了旧的 deb 版本号。断言 `4.21` 是库的真实版本。

```bash
out="$(chroot "${rootfs}" /usr/bin/python3 -c \
  'from importlib.metadata import version; print(version("protobuf"))')"
echo "${out}" | grep -Fq "4.21"
```
**验证 egg-info 切进来了**。`importlib.metadata.version()` 会去
`dist-packages` 下找 `*.egg-info` / `*.dist-info` 目录读 `PKG-INFO`。
egg-info 没切的话这里会抛 `PackageNotFoundError`。

这条断言精确对应 SDF 里那行 `protobuf-*.egg-info/**`。

```bash
cp test_protobuf.py "${rootfs}/test_protobuf.py"
out="$(chroot "${rootfs}" /usr/bin/python3 /test_protobuf.py)"
echo "${out}" | grep -Fq "ALL-PROTOBUF-CHECKS-PASSED"
echo "${out}" | grep -Fq "implementation python"
```
把功能脚本拷进 rootfs 跑。两条断言：脚本跑到最后（所有内部 assert 都过了），
以及**实现类型是纯 Python**。

后一条是在记录 Ubuntu 的打包事实：这个 deb 不带 C 扩展。如果哪天 Ubuntu 开始
提供 upb 实现，这条会失败 —— 那时就该重新审视切片是否漏了 `.so` 文件。

### `test_protobuf.py` 逐段解释

```python
from google.protobuf import __version__ as pb_version
from google.protobuf import json_format, proto_builder, text_format
from google.protobuf.internal import api_implementation
from google.protobuf import descriptor_pb2, duration_pb2, struct_pb2, timestamp_pb2

print("version", pb_version)
print("implementation", api_implementation.Type())
```
把要用到的模块全部 import。这本身就是覆盖 —— 每个 import 都在验证对应的
`.py` 文件被切进来了，而且它自己的依赖链（`descriptor`、`descriptor_pool`、
`internal.builder`、`internal.python_message` 等等）也都完整。

`api_implementation.Type()` 返回 `"python"` / `"upb"` / `"cpp"`。

#### 1. well-known types 的序列化往返

```python
ts = timestamp_pb2.Timestamp()
ts.FromJsonString("2026-04-23T17:07:15Z")
wire = ts.SerializeToString()
again = timestamp_pb2.Timestamp()
again.ParseFromString(wire)
assert again == ts
assert again.ToJsonString() == "2026-04-23T17:07:15Z"
```
**核心功能：序列化 → 反序列化 → 内容一致**。

用 `Timestamp` 是因为它同时覆盖了：
- `well_known_types.py` 里的 `FromJsonString` / `ToJsonString`
  （RFC 3339 时间格式解析，包括闰秒和纳秒处理）
- `internal/encoder.py` + `decoder.py` 的 varint 编解码
- Message 的 `__eq__`（基于字段逐一比较）

断言 `again == ts` 比"没抛异常"强 —— 它要求往返后**每个字段的值都相同**。
再断言 JSON 字符串也相同，是端到端的闭环。

```python
d = duration_pb2.Duration()
d.FromSeconds(90)
assert d.ToJsonString() == "90s"
```
`Duration` 的 JSON 表示是 `"90s"` 这种带单位的字符串，走的是
`well_known_types.py` 里另一段转换逻辑。

#### 2. Struct + json_format

```python
s = struct_pb2.Struct()
s.update({"name": "chisel", "count": 3, "ok": True, "items": [1, 2]})
as_json = json.loads(json_format.MessageToJson(s))
assert as_json == {"name": "chisel", "count": 3, "ok": True, "items": [1, 2]}
back = json_format.Parse(json.dumps(as_json), struct_pb2.Struct())
assert back == s
```
`Struct` 是 protobuf 里表示"任意 JSON"的类型，内部是
`map<string, Value>`，`Value` 是个 oneof（可以是 null/number/string/bool/
Struct/ListValue）。

这段覆盖了：
- **map 字段**和 **oneof 字段**的处理（protobuf 里最复杂的两种字段类型）
- **嵌套消息**（`items` 是 ListValue，里面又是 Value）
- `json_format` 双向转换

断言用的是 Python 字典相等比较，所以类型也要对得上（`3` 不能变成 `3.0`,
`True` 不能变成 `1`）—— 实际上 protobuf 的 Value 内部把数字都存成 double，
`json_format` 负责在输出时还原成整数，这条断言正好覆盖那段逻辑。

#### 3. text_format

```python
text = text_format.MessageToString(ts)
assert "seconds:" in text
parsed = text_format.Parse(text, timestamp_pb2.Timestamp())
assert parsed == ts
```
protobuf 还有一种人类可读的文本格式（调试和配置文件常用）：

```
seconds: 1776964035
```

同样做往返验证。这是 `text_format.py` 这个独立模块，和 json_format 无关。

#### 4. 运行时构造消息类型（不需要 protoc）

```python
Cls = proto_builder.MakeSimpleProtoClass(
    {"host": descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
     "port": descriptor_pb2.FieldDescriptorProto.TYPE_INT32},
    full_name="chisel.Endpoint",
)
msg = Cls(host="example.invalid", port=8080)
rt = Cls()
rt.ParseFromString(msg.SerializeToString())
assert rt.host == "example.invalid" and rt.port == 8080
```
**这段是整个测试里最能体现"库真的能用"的部分。**

`proto_builder.MakeSimpleProtoClass` 在运行时凭一个字段字典**动态生成**一个
消息类 —— 不需要 `.proto` 文件，不需要 `protoc` 编译器（那在另一个包里，
没切）。

它内部要做的事非常多：构造 `FileDescriptorProto` → 注册进
`descriptor_pool` → 生成 `Descriptor` 对象 → 用元类
（`internal/python_message.py` 的 `GeneratedProtocolMessageType`）
动态合成类和字段访问器。

所以这一段一次性验证了 descriptor 系统、descriptor pool、消息元类、
字段访问器生成这整套机制。然后再做一次序列化往返确认生成的类真的能用。

用 `example.invalid` 这个域名是因为它按 RFC 2606 保证永远不会被解析
（测试里不会有人误以为要联网）。

#### 5. 描述符

```python
fields = [f.name for f in timestamp_pb2.Timestamp.DESCRIPTOR.fields]
assert fields == ["seconds", "nanos"]
```
反射：从预生成的类上读出描述符，列出字段名，断言**顺序和内容都对**
（不是 `set` 比较）。

```python
fdp = descriptor_pb2.FileDescriptorProto()
fdp.name = "chisel.proto"
fdp.package = "chisel"
m = fdp.message_type.add()
m.name = "Thing"
f = m.field.add()
f.name = "label"
f.number = 1
f.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
f.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
rt = descriptor_pb2.FileDescriptorProto()
rt.ParseFromString(fdp.SerializeToString())
assert rt.message_type[0].field[0].name == "label"
```
手工构造一个 `FileDescriptorProto`（描述一个 `.proto` 文件的结构），
再序列化往返。

这段有意思的地方在于**自举**：描述符本身也是 protobuf 消息。
它覆盖了 **repeated 字段**（`message_type`、`field` 都是列表，用 `.add()`
追加子消息）和**枚举字段**（`TYPE_STRING`、`LABEL_OPTIONAL`），
是前面几段没覆盖到的字段类型。

#### 6. unknown fields 保留

```python
raw = Cls(host="a", port=1).SerializeToString()
other = timestamp_pb2.Timestamp()
other.ParseFromString(raw)
assert len(other.SerializeToString()) == len(raw)
```
**这条验证 protobuf 最重要的兼容性保证。**

我拿 `Endpoint`（字段 1 = string host、字段 2 = int32 port）的字节流，
去喂给 `Timestamp`（字段 1 = int64 seconds、字段 2 = int32 nanos）。

字段编号相同但类型不同，`Timestamp` 认不出这些数据，于是把它们存进
**unknown fields** 区。protobuf 的规范要求：再次序列化时必须把 unknown fields
**原样写回去**。

所以断言序列化后的长度和原始字节流相同 —— 说明没有任何数据在往返中丢失。

这正是 protobuf 支持"新老版本程序互通"的底层机制：老程序收到带新字段的消息，
即使不理解也会完整保留，转发出去时新字段还在。

这段代码路径在 `internal/python_message.py` 和 `unknown_fields.py` 里，
是前面所有测试都不会触及的。
