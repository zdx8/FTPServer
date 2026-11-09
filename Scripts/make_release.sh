#!/bin/bash
# 生成可发布的 Release 附件：通用二进制 .app 的 DMG 磁盘映像 + SHA256 校验文件。
#
# 用法：
#   bash Scripts/make_release.sh
#
# 产出（release/ 目录）：
#   FTPServer-macOS-<架构>.dmg
#   FTPServer-macOS-<架构>.dmg.sha256
#
# 命名规范（全项目统一）：软件名-系统-架构
#   FTPServer     软件名（与产品/可执行文件同名，不含空格）
#   macOS         系统
#   universal     架构；单架构时为 arm64 或 x86_64
#
# 文件名里**不带版本号**，这样官网与 README 可以用永久链接：
#   https://github.com/<owner>/<repo>/releases/latest/download/FTPServer-macOS-universal.dmg
# 版本号写在 Release 标题、tag 与包内 Info.plist 里，也印在 DMG 的使用说明中。
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="release"
APP_DIR="dist/FTPServer.app"
VOL_NAME="FTP Server"

echo "==> 编译并打包通用二进制应用"
# 发布包不做本机图标缓存刷新，避免 CI 里弹 Dock/访达
UNIVERSAL=1 SKIP_ICON_CACHE_REFRESH=1 bash Scripts/package_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_DIR}/Contents/Info.plist")"
ARCHS="$(lipo -archs "${APP_DIR}/Contents/MacOS/FTPServer")"

echo "==> 校验产物架构：${ARCHS}"
case "${ARCHS}" in
  *arm64*x86_64*|*x86_64*arm64*) ARCH_LABEL="universal" ;;
  *arm64*)                       ARCH_LABEL="arm64" ;;
  *x86_64*)                      ARCH_LABEL="x86_64" ;;
  *) echo "    错误：无法识别产物架构"; exit 1 ;;
esac

# 发布用的 DMG 必须双架构；单架构只会出现在本地调试构建里
case "${ARCH_LABEL}" in
  universal) ;;
  *) echo "    错误：发布产物缺少双架构（当前 ${ARCHS}）"; exit 1 ;;
esac

DMG_NAME="FTPServer-macOS-${ARCH_LABEL}.dmg"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"

mkdir -p "${OUT_DIR}"
STAGE="$(mktemp -d)/stage"
mkdir -p "${STAGE}"

echo "==> 组织磁盘映像内容"
cp -R "${APP_DIR}" "${STAGE}/FTPServer.app"
cp LICENSE "${STAGE}/LICENSE"

# 拖放安装：DMG 里放一个指向 /Applications 的符号链接，用户把 app 拖过去即可
ln -s /Applications "${STAGE}/Applications"

# 附件是 ad-hoc 签名，下载后会被 Gatekeeper 拦下，需要随包附上处理说明
cat > "${STAGE}/使用前请先阅读.txt" <<'README'
FTP Server for macOS —— 使用前请先阅读
========================================

一、怎么安装
------------
把 FTPServer.app 拖到旁边的「Applications」（应用程序）文件夹即可。

二、首次打开被系统拦下怎么办
----------------------------
本应用使用 ad-hoc（临时）签名，从网络下载后会被 macOS 加上隔离属性，
直接双击会提示「无法打开，因为无法验证开发者」或「已损坏」。这不是文件损坏。

任选一种方式解除：

  方式一（推荐）：在「应用程序」里找到 FTPServer，
                  按住 Control 点按（或右键）→ 选择「打开」，
                  在弹窗中再点一次「打开」。之后即可正常双击启动。

  方式二：打开「终端」，执行下面这行：

      xattr -dr com.apple.quarantine /Applications/FTPServer.app

  方式三：自己从源码构建，完全绕开签名问题：

      swift build -c release --disable-sandbox
      bash Scripts/package_app.sh

三、启动之后
------------
- 首次启动会自动创建共享目录：
      ~/FTP Share/           默认共享根目录
      ~/FTP Share/Public/    匿名访问根目录（默认只读）
- 默认监听端口是 2121，不是 21。21 端口需要 root 权限，刻意避开以便双击即用。
- 在「设置」里可改端口、绑定范围、超时；在「用户账号」里添加账号并指定各自根目录与权限。
- 菜单栏常驻：可在设置中选择关闭窗口后「最小化到菜单栏」，服务继续在后台运行。

四、用什么客户端连接
--------------------
macOS 自 10.13 起已移除 FTP 支持，访达无法连接本服务。

  图形客户端：Cyberduck、FileZilla、Transmit 等
  命令行：    curl ftp://127.0.0.1:2121/
              curl -u 用户名:口令 -T 本地文件 ftp://127.0.0.1:2121/远程文件名

五、相关链接
------------
  项目主页：https://github.com/zdx8/FTPServer
  官网：    https://zdx8.github.io/FTPServer/
  问题反馈：https://github.com/zdx8/FTPServer/issues

本项目以 MIT 许可开源。当前不支持 FTPS（加密）与 SFTP，仅适合局域网内的明文传输场景。
README

cat >> "${STAGE}/使用前请先阅读.txt" <<TXT

六、版本信息
------------
  版本号：${VERSION}
  构建号：${BUILD}
  架构：  ${ARCHS}（${ARCH_LABEL}）
  文件名：${DMG_NAME}
  校验：  shasum -a 256 -c ${DMG_NAME}.sha256

  查看本机已安装的版本：
      /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \\
        /Applications/FTPServer.app/Contents/Info.plist
TXT

rm -f "${DMG_PATH}" "${DMG_PATH}.sha256"

echo "==> 生成 DMG（UDZO 压缩）"
# -srcfolder 会把暂存目录的**内容**放到映像根目录，符号链接一并保留。
# UDZO = 只读 + zlib 压缩，是分发的常规格式；-ov 覆盖同名旧文件。
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  -quiet \
  "${DMG_PATH}"

echo "==> 挂载校验内容"
# attach 的输出每行是「设备<TAB>类型<TAB>挂载点」，取最后一个字段即挂载点
MOUNT_POINT="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly | tail -1 | awk -F'\t' '{print $NF}')"

cleanup() {
  if [ -n "${MOUNT_POINT:-}" ] && [ -d "${MOUNT_POINT}" ]; then
    hdiutil detach "${MOUNT_POINT}" -quiet || true
  fi
}
trap cleanup EXIT

if [ ! -d "${MOUNT_POINT}/FTPServer.app" ]; then
  echo "    错误：DMG 内没有 FTPServer.app"
  exit 1
fi
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${MOUNT_POINT}/FTPServer.app/Contents/Info.plist")"
MOUNTED_ARCHS="$(lipo -archs "${MOUNT_POINT}/FTPServer.app/Contents/MacOS/FTPServer")"
echo "    映像内版本：${MOUNTED_VERSION}　架构：${MOUNTED_ARCHS}"

hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

echo "==> 计算校验和"
( cd "${OUT_DIR}" && shasum -a 256 "${DMG_NAME}" | tee "${DMG_NAME}.sha256" )

echo ""
echo "==> 完成"
echo "    版本      ：${VERSION}（构建 ${BUILD}）"
echo "    架构      ：${ARCHS}（${ARCH_LABEL}）"
echo "    磁盘映像  ：${DMG_PATH}（$(du -h "${DMG_PATH}" | cut -f1)）"
echo "    校验文件  ：${DMG_PATH}.sha256"
echo ""
echo "    附件名为固定名（不带版本号），官网 releases/latest/download/${DMG_NAME}"
echo "    的永久链接可直接指向本文件。"
