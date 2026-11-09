# FTP Server 交接文档

> 补写日期：2026-10-24（历史项目补档，非交付时原始文档）

## 1. 一句话结论

FTP Server for macOS 是一个用 Swift + `Network.framework` 从零实现的原生 FTP 服务端桌面应用（RFC 959 + MLSD/MLST + EPSV），带 SwiftUI 界面、多账号、实时速率曲线与无界面 CLI，状态为**可交付（v1.0.1）**。适合在局域网内把 Mac 变成临时文件服务器（相机素材、备份中转），**不适合暴露公网**：不支持 FTPS/SFTP、口令哈希无 KDF。

## 2. 交付物与位置

| 交付物 | 路径 | 版本 | 校验 |
|---|---|---|---|
| 发布磁盘映像 | `release/FTPServer-macOS-universal.dmg` | 1.0.1（通用二进制） | SHA-256 `e98edab0beb34f0f662c4c4d70319142ebe0c1ad6a377b82f1f58cda27301e73`（2,779,435 字节） |
| 校验文件 | `release/FTPServer-macOS-universal.dmg.sha256` | — | 96 字节，内容与上表哈希一致（本次 `shasum -a 256` 复算一致） |
| 应用包 | `dist/FTPServer.app` | `CFBundleShortVersionString` = 1.0.1，`CFBundleVersion` = `261109.2307`，`com.zdx8.ftpserver` | 4.6 MB，ad-hoc 签名（含 `_CodeSignature`）；2026-11-09 界面重构后重打 |
| 官网静态页 | `docs/`（`index.html`、`icon.png`、`icon-512.png`、两张截图） | 页面静态值 v1.0.1 | 版本与附件大小由脚本动态读 Release 覆盖 |
| 源码 | 本目录，`main` 分支（tag `v1.0.1`） | 1.0.1 | 工作区干净 |

远程仓库：`origin` = `https://github.com/zdx8/FTPServer.git`（2026-11-09 由 `FTPServer-macOS` 改名，旧地址仍 301 跳转）；`gitea` = `ssh://gitea/ZYG/FTPServer-macOS.git`（**尚未改名**，仓库名仍是旧值，需在 Gitea 界面或 API 改后再更新本行）。tag：`v1.0.0`（`2e0692c`，旧界面 zip）、`v1.0.1`（界面重构，DMG）。

**发布状态**：README 与 `docs/index.html` 都指向 GitHub Releases 的固定附件名 `FTPServer-macOS-universal.dmg`（`releases/latest/download/...`，故链接永远指向最新版）；仓库内**没有 `gh-pages` 分支**，官网源为 `main` 的 `docs/`。线上状态（2026-11-09 实测）：新官网 `https://zdx8.github.io/FTPServer/` 返回 200，旧 Pages 地址 `/FTPServer-macOS/` 已 404（Pages 不随仓库改名跳转，外部旧链接需自行更新）。**线上最新 Release 为 v1.0.1**（界面重构 + DMG 附件），与本地 `release/` 同源。

> 附件名故意**不带版本号**（`Scripts/make_release.sh` 注释说明：官网永久链接需要固定名），版本号只写在 Release 标题、tag 与包内 `Info.plist`。
>
> 附件命名统一为 `<软件名>-<系统>-<架构>.<扩展名>`，故保留 `-macOS` 段（系统名），与仓库名 `FTPServer` 不冲突。文件名不带版本号是刻意的：`releases/latest/download/<固定名>` 才能永久指向最新版。

## 3. 怎么跑起来

命令取自 `README.md` 与 `Scripts/package_app.sh` / `make_release.sh`；**本次未执行构建**，首次构建耗时 `未验证：本次未执行构建，接手人需自行确认`。

本机实测环境：macOS 27.2（Build 26B118）、arm64、Swift 6.4（swiftlang-6.4.0.34.1）、Python 3.13.12；CLT SDK 含 `MacOSX26.5.sdk` / `MacOSX27.sdk`。README 记录的开发环境是 macOS 27.0 / Xcode 26.6 / Swift 6.3.3（旧于当前机器，未复验）。

```bash
cd "<仓库根>"

# 编译
swift build -c release --disable-sandbox

# 打包成 dist/FTPServer.app（含图标生成 + LaunchServices 登记 + 重启 Dock/Finder）
bash Scripts/package_app.sh
# 通用二进制、且不刷新本机图标缓存：UNIVERSAL=1 SKIP_ICON_CACHE_REFRESH=1 bash Scripts/package_app.sh

# 启动
open dist/FTPServer.app

# 出 Release 附件（自动 UNIVERSAL=1 + 计算 SHA256）
bash Scripts/make_release.sh
```

无界面模式（同一二进制，适合 launchd）：

```bash
dist/FTPServer.app/Contents/MacOS/FTPServer --headless \
  --port 2121 \
  --root ~/FTP\ Share \
  --user alice '<口令>' ~/alice-share rwmd \
  --user guest '<口令>' ~/FTP\ Share/Public r
# 其他参数：--localhost / --pasv-host <IPv4> / --log-level debug|info|warning|error / --anonymous-root <目录>
```

前置条件：

- macOS 14.0+；构建需 Swift 5.9+ 工具链（`swift-tools-version: 5.9`）。
- 默认端口 **2121**（21 需 root，刻意避开）；防火墙需放行，绑定局域网时系统会弹「本地网络」权限。
- 首次启动自动创建 `~/FTP Share/` 与 `~/FTP Share/Public/`。
- 访达无法连接（macOS 10.13 起移除 FTP 客户端），需 Cyberduck / FileZilla / Transmit 或 `curl ftp://127.0.0.1:2121/`。

## 4. 架构与关键设计

```
FTPServerApp.swift（按参数分流 GUI / --headless）
├─ Headless.swift              无界面入口，构造 ServerConfig 直接 start
├─ UI/                         只做展示与转发
│   ├─ BenchoTheme             设计令牌层：颜色/圆角/间距/动效/字体，上游取自 bencho（MIT）
│   ├─ Components              基础零件：BenchoButtonStyle、LiquidSwitch、BenchoSegmented、
│   │                          ToastCenter + ToastStackView、BenchoTilt、CardContainer、
│   │                          StatCard、ServerControlBar、AddressRow、SettingRow、Hairline
│   ├─ ServerViewModel         配置持久化、统计采样、日志缓冲；单例
│   └─ 概览 / 活动会话 / 日志 / 用户账号 / 设置 + MenuBarPanel + ThemeController
├─ Core/                       不依赖 SwiftUI，可被测试直接编译
│   ├─ FTPServer               监听、接入限流、会话注册表、统计与日志分发
│   ├─ FTPSession              控制连接状态机与全部命令（814 行）
│   ├─ FTPSession+Transfer     数据通道、PASV/PORT/EPSV、REST/RETR/STOR/APPE
│   ├─ FTPDataChannel          发送器/接收器、ASCII 转换、文件源与汇
│   ├─ FTPVirtualFileSystem    虚拟路径规范化、软链边界、LIST/MLSD 格式化
│   ├─ Models                  配置、账号、口令散列、日志、错误
│   └─ NetworkInterface        网卡枚举（PASV 通告与界面展示）
└─ Scripts/                    打包、e2e、selfcheck、uicheck、图标
```

规模实测：`Sources/` 21 个 Swift 文件 / 6,249 行（其中 UI 层 3,245 行）；`Scripts/e2e_test.py` 683 行（70 处 `check(` 调用点，README 称 100 项断言）、`Scripts/selfcheck/main.swift` 304 行（35 处 `check(`）、`Scripts/uicheck/main.swift` 180 行（15 处，当前工具链下无法编译，见第 5 节）。

关键决策：

- **用 `Network.framework` 而不是 BSD socket** → 连接生命周期、队列与取消由框架管理，避免手写 socket 状态机 → 代价是无法做底层 socket 调优（如自定义 buffer/keepalive 参数）→ 若要做高并发或特殊网络语义，才考虑下移。
- **每个会话一条串行队列，控制与数据连接共用** → 命令天然串行、无需为每条命令加锁；所有回调异步链式推进、不阻塞队列 → 代价是同一会话内大文件传输会占住该队列（仅影响本会话）→ 若需要控制连接在传输中仍能处理 `ABOR`，需确认现有异步链是否已覆盖（源码有 ABOR/看门狗，未逐行复核）。
- **口令加盐 SHA-256 + 恒定时间比较** → 避免明文落盘与账号枚举 → 代价是无 PBKDF2/scrypt 密钥拉伸，弱口令可离线爆破 → 若要公网暴露，必须先引入 KDF + TLS。
- **路径双重校验（逐段消 `.`/`..` + 解析软链后校验目标仍在根内）** → FTP 客户端可传任意路径，软链可绕过父目录校验 → 代价是每次读写多一次 `realpath` 解析 → 不可推翻。
- **ad-hoc 签名 + 固定附件名** → 无开发者证书时保证本机可运行，官网可用永久链接 → 代价是他人下载后必被 Gatekeeper 拦 → 拿到证书后应改为「签名 + 公证 + 装订」。
- **界面沿用 bencho 的设计语言，但重写为原生 SwiftUI** → bencho 是 React 组件集（framer-motion / three.js / Web Audio），与 SwiftUI 无代码级互通；引入它只有两条路：WebView 承载整个 UI（包体 3.1→10 MB+、菜单栏与原生快捷键要重做桥接），或改 Electron（3,004 行 Core 需重写）→ 故选第三条：把 `tokens.css` 的语义色、圆角与动效曲线映射为 `BenchoTheme`，把 8 个可对应的交互范式（液体开关、Toast 栈、滚动数字、磁吸分段、悬停倾斜、堆叠流量条、权限胶囊、反色选中态）用 SwiftUI 重写 → 代价是动效为**近似实现**（上游的 SVG goo 滤镜在 SwiftUI 无等价物，液态开关改用胶囊拉伸近似），不是逐像素一致 → 若日后要求与 bencho 逐像素对齐，才需要考虑 WebView 方案。

## 5. 已完成 / 未完成 / 已知问题

**已完成**：PASV/EPSV/PORT 三种数据通道（含 bounce 防护）；二进制/ASCII 双向转换（跨块不错切 CRLF）；`REST` 断点续传、`APPE` 追加；目录操作 `PWD/CWD/CDUP/MKD/RMD/DELE/RNFR/RNTO` 与 `X*` 别名；`SIZE/MDTM/MLST/STAT`、`FEAT`；匿名 + 多账号（独立根目录 + `r/w/d/m` 权限位）；空闲超时、数据停滞看门狗、`ABOR`、异常断开清理；实时速率曲线、逐会话流量、分级日志（口令打码）；菜单栏常驻；浅/深色主题；无界面 CLI。

**未完成（README 明确列出，非缺陷）**：不支持 FTPS（`AUTH TLS` → 502）与 SFTP；未实现 `STOU/REIN/SMNT/SITE`（统一 502）；无速率限制、磁盘配额、目录级 ACL；无公证。

**已知问题**：

- **已修复｜打包脚本 bash 3.2 兼容**：`Scripts/package_app.sh` 的 `"${ARCH_FLAGS[@]}"` 已改为 `${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}`，修复 `set -u` 下空数组展开报 `unbound variable`。2026-11-09 随界面重构一并提交，v1.0.0 tag 内仍是旧写法。
- **影响体验｜口令哈希无 KDF**：加盐 SHA-256 对局域网可信共享够用，公网场景不足（README「安全模型」附注已声明）。
- **影响体验｜ad-hoc 签名**：拷到别的机器必被 Gatekeeper 拦；需右键打开或 `xattr -dr com.apple.quarantine`。
- **边缘｜README 测试数与实际调用点数不一致**：README 称 e2e「100 项断言」，源码 `check(` 调用点为 70（循环内可能多次执行）。**2026-11-09 已实跑：100/100 通过（11.8 秒）**，口径以实跑为准。
- **影响体验｜界面层回归测试当前无法编译**：`Scripts/uicheck/main.swift` 直接用 `swiftc` 编译时，SwiftUI 的 `@State` 宏报 `SwiftUIMacros.StateMacro ... malformed response`（Xcode 26 的 swift-plugin-server 在 Swift 6.4.2 工具链下的故障，与本次改动无关，改动前的旧版同样编译不过）。**替代验证**：真机启动 + 窗口级截图逐页核对（浅色/深色、空态与真实会话各一轮），并由 e2e 的 100 项覆盖协议层。修复方向：改用 `swift build` 的 target 承载该自检，或换回带完整宏插件路径的 Xcode 工具链。
- **边缘｜开关与分段控件不参与键盘 Tab 焦点**（有意）：`LiquidSwitch` 自绘胶囊，接入 `.focusable()` 后系统焦点环会在药丸外再套一圈高亮，且窗口启动时首个可聚焦视图会自动取得焦点、常驻光晕。故只保留 VoiceOver 的 `accessibilityAction`，键盘路径是 ⌘R 启停服务；`BenchoSegmented` 同理，需鼠标点选。
- **边缘｜Toast 落点固定在右下角**：右上角是启停开关与主按钮，早前版本放在右上会遮挡操作，且 overlay 铺满整层时会吃掉 2.6 秒内的全部点击。现改为按内容尺寸贴右下，不拦截其他区域的指针事件。
- **提示｜v1.0.0 的 zip 附件仍在**：v1.0.1 起附件格式为 DMG；v1.0.0 那个 Release 保留历史原样（旧界面 + zip），不删不改，仅作历史版本。

## 6. 外部依赖与凭据

- SwiftPM 依赖：**无第三方包**；实际 import 为 SwiftUI / AppKit / Network / Charts / Combine / CryptoKit / Darwin / Foundation。
- 许可证：MIT（`LICENSE`，1,061 字节）。
- 凭据位置：**账号口令散列**保存在 `~/Library/Application Support/FTPServer/config.json` 的账号条目里（加盐 SHA-256，非明文）。本文档不复制该文件内容。查看有哪些账号（不打印散列）：
  ```bash
  python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/Library/Application Support/FTPServer/config.json')));print([a.get('username') for a in d.get('accounts',[])])"
  ```
- 分发凭据：代码托管 SSH key 在 `~/.ssh/`，钥匙串条目仅供推送到 GitHub/Gitea；不放文档。
- 客户端连接口令由用户自设，**不要写进任何提交或文档**；日志里 `PASS`/`ACCT` 参数会被打码。

## 7. 数据与配置在哪

- 配置：`~/Library/Application Support/FTPServer/config.json`（端口、绑定范围、默认/匿名根目录、超时、最大连接、账号与口令散列、日志级别、关窗行为）。
- 配置损坏时自动改名为 `config.corrupt-<epoch>.json` 并回退默认值（`ServerViewModel.loadConfig`）。
- 共享目录：默认 `~/FTP Share/`，匿名根 `~/FTP Share/Public/`（默认只读）；账号可各自指定根目录。
- 日志：**只在内存**（界面「运行日志」页，可过滤/搜索/复制），不落盘。
- 无数据库、无缓存目录。

重置到初始状态（先退出应用；配置里有账号散列，建议备份）：

```bash
osascript -e 'quit app "FTP Server"' 2>/dev/null
mv ~/Library/Application\ Support/FTPServer ~/Desktop/FTPServer-config-backup-$(date +%Y%m%d-%H%M)
# 需要连共享目录一起重置时（会动用户文件，先确认）：
# mv ~/FTP\ Share ~/Desktop/FTP-Share-backup-$(date +%Y%m%d-%H%M)
```

## 8. 维护手册（出问题先看这里）

| 现象 | 排查步骤 | 日志位置 |
|---|---|---|
| 双击提示「无法验证开发者/已损坏」 | `codesign -dv dist/FTPServer.app` 确认 ad-hoc；右键 → 打开；或 `xattr -dr com.apple.quarantine` | 系统「隐私与安全性」 |
| 客户端连不上（本机） | `curl -v ftp://127.0.0.1:2121/`；确认服务已启动、端口未被占用：`lsof -nP -iTCP:2121` | 界面「运行日志」 |
| 局域网其他设备连不上 | 确认不是 `--localhost`；系统设置 → 网络 → 防火墙放行；首次运行需授予「本地网络」权限；`NetworkInterface` 列出的地址是否与客户端同网段 | 界面「运行日志」 |
| PASV 能登录但列目录卡住 | NAT/多网卡下 PASV 通告地址不对，设 `--pasv-host <IPv4>` 或在设置里填「被动模式对外地址」 | 界面「运行日志」 |
| 上传/下载中断 | 看是否触发空闲/数据停滞超时（设置页可调）；确认目标目录权限位含 `w`；日志里 550/425 响应码 | 界面「运行日志」 |
| 账号登录失败 | 确认账号根目录存在且可读；权限位（`r/w/d/m`）是否覆盖该操作；口令散列不匹配只能重建账号 | 界面「运行日志」（PASS 已打码） |

## 9. 复现与验证清单

```bash
cd "<仓库根>"

# 1. 版本与 bundle
plutil -p dist/FTPServer.app/Contents/Info.plist | grep -E "ShortVersion|BundleVersion|Identifier"
# 预期：1.0.1 / 261109.2307 / com.zdx8.ftpserver

# 2. 架构（dist 里是最后一次构建；make_release.sh 会断言 DMG 内为双架构）
lipo -archs dist/FTPServer.app/Contents/MacOS/FTPServer
# 预期：arm64；zip 内是否真为通用二进制 `未验证：未解压核对`

# 3. 发布包校验（本地复算应与 .sha256 文件一致）
shasum -a 256 -c release/FTPServer-macOS-universal.dmg.sha256
# 预期：FTPServer-macOS-universal.dmg: OK（哈希 e98edab0…01e73，2,779,435 字节）

# 4. 仓库状态
git log -1 --oneline && git tag && git status --porcelain
# 预期：干净工作区 / tag 含 v1.0.0 与 v1.0.1

# 5. 源码规模
find Sources -name "*.swift" | wc -l && find Sources -name "*.swift" -exec wc -l {} + | tail -1
# 预期：20 / 5273 total

# 6. 协议一致性测试（需运行，会临时起服务）
swift build -c release --disable-sandbox
python3 Scripts/e2e_test.py "$(swift build -c release --show-bin-path --disable-sandbox)/FTPServer" 21321
# 预期：README 称 100 项断言全过；本次未运行

# 7. Core 层自检（需运行）
swiftc -O -o /tmp/sc Sources/FTPServer/Core/*.swift Scripts/selfcheck/main.swift && /tmp/sc
# 预期：35 处 check 全过（README 覆盖会话发布/两种绑定/配置兼容/软链写入防护/截断检测）
```

## 10. 下一步建议

1. **先提交或丢弃 `package_app.sh` 的未提交修复**：这是 `set -u` 下真实会中断打包的 bug，留在工作区会被下一次 `git checkout` 无声丢掉。只动该脚本 + 一次提交。
2. **补 FTPS（`AUTH TLS`）**：当前明文传输是最大短板；动 `FTPSession.swift`（命令状态机）、`FTPDataChannel.swift`（TLS 包装）、`Models.swift`（证书配置）。
3. **口令 KDF**：把加盐 SHA-256 换成 PBKDF2/scrypt，并保留旧散列的登录迁移路径；动 `Models.swift` 的口令散列与校验。
4. **日志落盘**：目前日志只在内存，出事无法事后取证；给 `Models.swift` 的日志分发加可选文件 sink（按天轮转）。
5. **公证发布流水线**：当前 `make_release.sh` 只做 ad-hoc；补证书分支（`codesign --options runtime` + `notarytool` + `stapler`）。

## 11. 变更历史

| 日期 | 版本 | 改了什么 |
|---|---|---|
| 2026-09-13 | — | `a66d8c2` 初始提交：原生 macOS FTP 服务端 |
| 2026-09-13 | v1.0.0 | `20fe4e0` 新增发布流程：通用二进制打包脚本（tag `v1.0.0`） |
| 2026-09-13 | v1.0.0 | `e5a6985` 官网重做：加入下载安装按钮；附件改为与版本无关的固定名（当前 HEAD） |
| 2026-09-13 | v1.0.0 | `release/` 产物生成于 14:45（zip 2,286,383 字节 + .sha256；现已弃用，见下行） |
| 未提交 | — | `Scripts/package_app.sh`：bash 3.2 空数组展开修复（工作区 ` M`，未进 v1.0.0） |
| 2026-11-09 | v1.0.0 | 界面按 bencho（MIT）设计语言重构：新增 `UI/BenchoTheme.swift` 令牌层，重写 `UI/Components.swift` 与六个视图；`dist/` 重打为 261109.2219（4.6 MB）；e2e 100/100、selfcheck 通过；`release/` 未重出 |
| 2026-11-09 | v1.0.0 | 标题栏与内容区同色：`.toolbarBackground(.hidden, for: .windowToolbar)` + `titlebarAppearsTransparent` + `window.backgroundColor = Bencho.bgNS`；实测浅色 `#FFFFFF`、深色 `#000000`，与页面底色一致，无分隔线 |
| 2026-11-09 | v1.0.0 | 缺陷修复：开关光标栈失衡（视图隐藏/禁用时未 pop）、拖拽松手回弹闪跳、窗口缩到 1000pt 以下会话表再次错位（改为内容最小尺寸兜底）、菜单栏主按钮胶囊不随宽度伸展、Toast 遮挡控制条并吃掉全层点击、卡片头部右侧胶囊基线偏移；`dist/` 重打 261109.2237 |
| 2026-11-09 | v1.0.0 | 仓库改名 `FTPServer-macOS` → `FTPServer`；官网/README 的仓库地址、API 端点、clone 目录名同步；截图按新界面重拍并改用 RFC 5737 地址；全仓脱敏（`com.zyg` → `com.zdx8`、绝对路径、测试夹具 IP）；历史对齐到脱敏后的单提交 `2e0692c` 后重建提交 |
| 2026-11-09 | v1.0.0 | 发布格式由 zip 改为 DMG：`Scripts/make_release.sh` 重写（hdiutil UDZO + `Applications` 软链 + 挂载校验版本与架构），附件名统一为 `<软件名>-<系统>-<架构>.dmg` 且不带版本号；官网与 README 的下载/校验/安装措辞同步改为 DMG |
| 2026-11-09 | **v1.0.1** | 首个含新界面的版本：bencho 设计语言、标题栏同色、六项缺陷修复；附件改为 DMG（通用二进制，2,779,435 字节 / `e98edab0…01e73`）；仓库已改名 `FTPServer` |
