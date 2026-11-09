# FTP Server for macOS

一个用 Swift 从零实现的原生 macOS FTP 服务端桌面应用。纯系统框架构建，**无任何第三方依赖**，可打包成双击即用的 `.app`。

- 协议：标准 FTP（RFC 959）+ RFC 3659 结构化列举（MLSD / MLST）+ RFC 2428 扩展被动模式（EPSV）
- 界面：原生 SwiftUI，含实时速率曲线、活动会话管理、分级日志、多账号管理、菜单栏常驻
- 网络层：Apple `Network.framework`，无 BSD socket 手工管理
- 体积：约 3 MB 的独立应用包

> **一句提醒**：macOS 自 10.13 起已移除 FTP 支持，**访达无法连接**本服务。请使用 Cyberduck、FileZilla、Transmit 等客户端，或直接用命令行 `curl ftp://127.0.0.1:2121/`。

---

## 下载安装

**[⬇︎ 下载最新版](https://github.com/zdx8/FTPServer/releases/latest/download/FTPServer-macOS-universal.dmg)** —— 通用二进制，Apple Silicon 与 Intel 均可直接运行。

| | |
|---|---|
| 系统要求 | macOS 14.0 或更高 |
| 文件名 | `FTPServer-macOS-universal.dmg`（约 2.7 MB） |
| 校验文件 | [SHA256](https://github.com/zdx8/FTPServer/releases/latest/download/FTPServer-macOS-universal.dmg.sha256) |
| 历史版本 | [所有 Releases](https://github.com/zdx8/FTPServer/releases) |

下载链接固定不变，始终指向最新版本。

**安装步骤**

1. 打开下载的 DMG，把 `FTPServer.app` 拖进「应用程序」文件夹。
2. **第一次打开**：在它上面按住 Control 点按（或右键）→ 选择「打开」→ 在弹出的确认框里再点一次「打开」。
   放行一次之后即可正常双击启动。
3. 启动后在「设置」里确认端口与共享目录，在「用户账号」里添加账号。

**为什么第一次会被拦下？** 本应用使用 ad-hoc（临时）签名，从网络下载后会被 macOS 加上隔离属性，
提示「无法验证开发者」或「已损坏」。这不是文件损坏。若右键打开仍被拦下：

```bash
xattr -dr com.apple.quarantine /Applications/FTPServer.app
```

彻底消除该提示需要开发者证书签名与公证；或者直接[从源码构建](#构建与打包)，完全绕开签名问题。

**校验下载**

```bash
shasum -a 256 -c FTPServer-macOS-universal.dmg.sha256   # 预期输出：OK
```

---

## 功能一览

| 能力 | 说明 |
|---|---|
| 传输模式 | 被动模式（PASV / EPSV）、主动模式（PORT），含 bounce 攻击防护 |
| 传输类型 | 二进制与 ASCII 双向转换，按 RFC 959 处理 CRLF/LF，跨分块边界不错切 |
| 断点续传 | `REST` 记录偏移 + `RETR`/`STOR` 续传；`APPE` 追加写 |
| 目录操作 | `PWD` `CWD` `CDUP` `MKD` `RMD` `DELE` `RNFR` `RNTO`，含 `X*` 旧式别名 |
| 元数据 | `SIZE` `MDTM` `MLST` `STAT`，`FEAT` 声明 `SIZE/MDTM/MLSD/REST STREAM/UTF8/TVSV/EPSV` |
| 认证 | 匿名访问（可单独开关与授权）+ 多账号（每账号独立根目录与 4 项权限位） |
| 并发 | 每会话独立串行队列，控制连接与数据连接分离；服务级最大连接数限制 |
| 健壮性 | 空闲超时、数据停滞看门狗、`ABOR` 中止、客户端异常断开自动清理 |
| 观测 | 实时上传/下载速率曲线、累计流量、逐会话流量、分级日志（可过滤/搜索/复制） |

## 界面

侧边栏分五区：

- **概览** — 运行状态、一键复制接入地址、实时速率曲线、累计统计
- **活动会话** — 客户端地址、登录用户、当前目录、传输状态、实时流量、最后命令，可单独断开
- **运行日志** — 按级别过滤、搜索、复制；口令参数自动打码
- **用户账号** — 增删改账号，设置根目录与权限位
- **设置** — 端口、绑定范围、共享目录、超时、被动模式对外地址、关闭窗口行为

**菜单栏常驻**：可关闭 Dock 图标退居菜单栏，面板内查看状态、启停服务、复制接入地址与日志摘要。

**主题**：工具栏右上角按钮在浅色 / 深色间切换，设置页可选「跟随系统」。

**视觉与交互语言**：界面采用 [bencho](https://github.com/cabralorenzo/bencho)（MIT）的设计令牌与交互范式，
在 SwiftUI 中重新实现，不含任何 Web 运行时与第三方依赖——纸白/纯黑两套底色、发丝线代替投影、
反色胶囊表示选中、液体开关、滚动数字、悬停倾斜与右上角 Toast 栈均为原生绘制。
`Sources/FTPServer/UI/BenchoTheme.swift` 记录全部取值的上游出处。

---

## 系统要求

- macOS 14.0 或更高
- 完整 Xcode 或 Swift 工具链（Swift 5.9+）

开发与验证环境：macOS 27.0 / Xcode 26.6 / Swift 6.3.3 / Apple Silicon。

## 构建与打包

```bash
# 编译
swift build -c release --disable-sandbox

# 打包成可双击运行的 dist/FTPServer.app（含图标生成与系统图标缓存刷新）
bash Scripts/package_app.sh
```

打包脚本会一并递增 `CFBundleVersion`、重新登记 LaunchServices 并重启 Dock / 访达，
确保换了图标后系统立即展示新版（macOS 的应用图标缓存以「bundle 标识 + 版本号 + 路径」为键，
版本号不变时会一直沿用旧图标）。

## 使用

### 图形界面

```bash
open dist/FTPServer.app
```

首次启动会自动创建共享目录：

```
~/FTP Share/          默认共享根目录
~/FTP Share/Public/   匿名访问根目录（默认只读）
```

在「用户账号」页添加账号并指定各自的根目录与权限；在「设置」页调整端口与绑定范围。

### 命令行（无界面模式）

同一份二进制自带无界面模式，便于脚本化或被 `launchd` 驱动：

```bash
dist/FTPServer.app/Contents/MacOS/FTPServer --headless \
  --port 2121 \
  --root ~/FTP\ Share \
  --user alice secret ~/alice-share rwmd \
  --user guest  guest  ~/FTP\ Share/Public r
```

| 选项 | 说明 |
|---|---|
| `--port <端口>` | 监听端口，默认 2121 |
| `--root <目录>` | 根目录（同时作为匿名根目录） |
| `--anonymous-root <目录>` | 单独指定匿名根目录 |
| `--localhost` | 仅绑定 127.0.0.1，不暴露到局域网 |
| `--pasv-host <IPv4>` | 被动模式对外通告地址（NAT / 多网卡环境） |
| `--log-level <级别>` | `debug` / `info` / `warning` / `error` |
| `--user <名> <口令> <根目录> [权限]` | 添加账号，可重复；权限为 `r` `w` `d` `m` 组合 |

`--help` 查看完整说明。

### 客户端连接

```bash
curl ftp://127.0.0.1:2121/
curl -u alice:secret -T local.txt ftp://127.0.0.1:2121/remote.txt
```

**默认端口是 2121 而非 21** —— 21 端口需要 root 权限，刻意避开以便双击即用。

---

## 安全模型

服务端在文件访问上做了双重边界校验，并在鉴权与日志上做了最小暴露：

**路径边界**

1. **虚拟路径规范化** —— 客户端路径先逐段消除 `.` / `..`。越出根目录的 `..` 是**明确拒绝**（550），不是静默钳制到根目录。
2. **符号链接包含性校验** —— 读、写、删、改名各条路径都会解析符号链接后校验目标仍位于根目录之内。

> 写入路径（`STOR` / `APPE` / `MKD`）的校验曾被遗漏：只校验了父目录，于是根目录内一个指向外部的软链接可以让客户端顺着它覆盖共享目录之外的任意可写文件。该缺陷已修复并纳入回归测试。

**鉴权**

- 口令以**加盐 SHA256** 存储，校验使用恒定时间比较
- 登录失败不区分「账号不存在」与「口令错误」，避免账号枚举
- 日志中 `PASS` / `ACCT` 参数一律打码
- `PORT` 命令限定回连地址必须与控制连接来源一致，防止 FTP bounce

**附注**：口令哈希未做密钥拉伸（无 PBKDF2 / scrypt）。对局域网内的可信共享场景，加盐 SHA256 已足够；若要暴露到公网，建议先引入 KDF 并启用加密传输。

---

## 测试

仓库自带三层可独立运行的测试，全部不依赖图形界面：

```bash
# 1) 协议一致性：以 Python ftplib 作为真实客户端，100 项断言
swift build -c release --disable-sandbox
python3 Scripts/e2e_test.py "$(swift build -c release --show-bin-path --disable-sandbox)/FTPServer" 21321

# 2) Core 层自检：会话发布、两种绑定模式、配置向后兼容、符号链接写入防护、下载源截断检测
swiftc -O -o /tmp/sc Sources/FTPServer/Core/*.swift Scripts/selfcheck/main.swift && /tmp/sc

# 3) 界面层：视图渲染回归 + 真实客户端到视图模型的端到端
swiftc -O -o /tmp/uc Sources/FTPServer/Core/*.swift Sources/FTPServer/UI/*.swift Scripts/uicheck/main.swift && /tmp/uc
```

协议测试覆盖：认证与权限拒绝、PASV / EPSV / PORT 三种数据通道、
`LIST` / `NLST` / `MLSD` / `MLST`、5 MB 随机数据与全字节域文件的哈希校验、
空文件、断点续传、ASCII 往返、Unicode 文件名、8 路并发，
以及 7 类路径逃逸与 5 类符号链接写入逃逸攻击（全部应被拒绝）。

---

## 已知边界

以下为**明确的未实现项**，不是缺陷：

- **不支持 FTPS**（`AUTH TLS` 返回 502）与 **SFTP**。FTPS 需要引入 TLS 通道，SFTP 基于 SSH 协议、实现量是 FTP 的数倍。
- 未实现 `STOU` / `REIN` / `SMNT` / `SITE`，统一返回 502。
- 无速率限制、无磁盘配额、无目录级 ACL（权限粒度是账号级的 4 个开关）。
- 打包使用 ad-hoc 临时签名，**仅适合本机使用**。拷贝到其他机器会被 Gatekeeper 拦截；对外分发需要开发者证书签名 + 公证。

## 目录结构

```
Package.swift
Sources/FTPServer/
├── Core/                     不依赖 SwiftUI，可被无界面模式与测试直接使用
│   ├── Models.swift              配置、账号、口令散列、日志、错误
│   ├── FTPServer.swift           监听、接入限流、会话注册表、统计与日志分发
│   ├── FTPSession.swift          控制连接状态机与全部命令
│   ├── FTPSession+Transfer.swift 数据通道、被动/主动模式、断点续传
│   ├── FTPDataChannel.swift      发送器 / 接收器 / ASCII 转换 / 文件源与汇
│   ├── FTPVirtualFileSystem.swift 虚拟路径规范化、符号链接边界、LIST 与 MLSD 格式化
│   └── NetworkInterface.swift    网卡地址枚举（被动模式通告与界面展示）
├── UI/                       只做展示与转发
├── Headless.swift            无界面模式入口
└── FTPServerApp.swift        SwiftUI App 入口（按参数分流 GUI / 无界面）
Scripts/                      图标生成、打包、测试与自检
docs/                         GitHub Pages 官网
```

**架构约定**：`Core/` 完全不依赖 SwiftUI；每个 `FTPSession` 拥有一条串行队列，
控制连接与数据连接共用，全链路异步链式推进、任何回调都不阻塞队列。

## 许可证

[MIT](LICENSE)
