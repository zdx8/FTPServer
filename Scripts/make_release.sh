#!/bin/bash
# 生成可发布的 Release 附件：通用二进制 .app 压缩包 + SHA256 校验文件。
#
# 用法：
#   bash Scripts/make_release.sh
#
# 产出（release/ 目录）：
#   FTPServer-<版本>-macOS-universal.zip
#   FTPServer-<版本>-macOS-universal.zip.sha256
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="release"
APP_DIR="dist/FTPServer.app"

echo "==> 编译并打包通用二进制应用"
# 发布包不做本机图标缓存刷新，避免 CI 里弹 Dock/访达
UNIVERSAL=1 SKIP_ICON_CACHE_REFRESH=1 bash Scripts/package_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_DIR}/Contents/Info.plist")"

# 附件名**不带版本号**：这样官网可以直接用永久链接
#   https://github.com/<owner>/<repo>/releases/latest/download/FTPServer-macOS-universal.zip
# 每次发版都能自动指向最新附件，不必同步改站点。
# 版本号写在 Release 标题、标签与包内的 Info.plist 里，用户不会定位不到自己下载的是哪一版。
ZIP_NAME="FTPServer-macOS-universal.zip"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"

ARCHS="$(lipo -archs "${APP_DIR}/Contents/MacOS/FTPServer")"
echo "==> 校验产物架构：${ARCHS}"
case "${ARCHS}" in
  *arm64*) ;;
  *) echo "    错误：产物缺少 arm64 架构"; exit 1 ;;
esac
case "${ARCHS}" in
  *x86_64*) ;;
  *) echo "    错误：产物缺少 x86_64 架构"; exit 1 ;;
esac

mkdir -p "${OUT_DIR}"
STAGE="$(mktemp -d)/stage"
mkdir -p "${STAGE}"

echo "==> 组织压缩包内容"
cp -R "${APP_DIR}" "${STAGE}/FTPServer.app"

# 附件是 ad-hoc 签名，下载后会被 Gatekeeper 拦下，需要随包附上处理说明
cat > "${STAGE}/使用前请先阅读.txt" <<'README'
FTP Server for macOS —— 使用前请先阅读
========================================

一、首次打开被系统拦下怎么办
----------------------------
本应用使用 ad-hoc（临时）签名，从网络下载后会被 macOS 加上隔离属性，
直接双击会提示「无法打开，因为无法验证开发者」或「已损坏」。这不是文件损坏。

任选一种方式解除：

  方式一（推荐）：把 FTPServer.app 拖进「应用程序」文件夹，
                  然后在它上面按住 Control 点按（或右键）→ 选择「打开」，
                  在弹窗中再点一次「打开」。之后即可正常双击启动。

  方式二：打开「终端」，执行下面这行（如果放在应用程序文件夹）：

      xattr -dr com.apple.quarantine /Applications/FTPServer.app

  方式三：自己从源码构建，完全绕开签名问题：

      swift build -c release --disable-sandbox
      bash Scripts/package_app.sh

二、启动之后
------------
- 首次启动会自动创建共享目录：
      ~/FTP Share/           默认共享根目录
      ~/FTP Share/Public/    匿名访问根目录（默认只读）
- 默认监听端口是 2121，不是 21。21 端口需要 root 权限，刻意避开以便双击即用。
- 在「设置」里可改端口、绑定范围、超时；在「用户账号」里添加账号并指定各自根目录与权限。
- 菜单栏常驻：可在设置中选择关闭窗口后「最小化到菜单栏」，服务继续在后台运行。

三、用什么客户端连接
--------------------
macOS 自 10.13 起已移除 FTP 支持，访达无法连接本服务。

  图形客户端：Cyberduck、FileZilla、Transmit 等
  命令行：    curl ftp://127.0.0.1:2121/
              curl -u 用户名:口令 -T 本地文件 ftp://127.0.0.1:2121/远程文件名

四、相关链接
------------
  项目主页：https://github.com/zdx8/FTPServer-macOS
  官网：    https://zdx8.github.io/FTPServer-macOS/
  问题反馈：https://github.com/zdx8/FTPServer-macOS/issues

本项目以 MIT 许可开源。当前不支持 FTPS（加密）与 SFTP，仅适合局域网内的明文传输场景。
README

# 附件名不含版本号（便于官网用永久链接指向最新版），版本信息写进说明文件
cat >> "${STAGE}/使用前请先阅读.txt" <<TXT

五、版本信息
------------
  版本号：${VERSION}
  构建号：${BUILD}
  架构：  ${ARCHS}
  校验：  shasum -a 256 -c ${ZIP_NAME}.sha256

  查看本机已安装的版本：
      /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \\
        /Applications/FTPServer.app/Contents/Info.plist
TXT
cp LICENSE "${STAGE}/LICENSE"

rm -f "${ZIP_PATH}" "${ZIP_PATH}.sha256"

echo "==> 压缩（保留符号链接与扩展属性）"
# 用 ditto 而非 zip：ditto 能正确保留 .app 包内的符号链接、权限位与扩展属性。
# 源给目录、且不加 --keepParent，归档的是该目录的**内容**，
# 解压后直接得到 FTPServer.app；加了 --keepParent 会多套一层暂存目录名。
ditto -c -k --sequesterRsrc "${STAGE}" "${ZIP_PATH}"

echo "==> 计算校验和"
( cd "${OUT_DIR}" && shasum -a 256 "${ZIP_NAME}" | tee "${ZIP_NAME}.sha256" )

echo ""
echo "==> 完成"
echo "    版本      ：${VERSION}（构建 ${BUILD}）"
echo "    架构      ：${ARCHS}"
echo "    压缩包    ：${ZIP_PATH}（$(du -h "${ZIP_PATH}" | cut -f1)）"
echo "    校验文件  ：${ZIP_PATH}.sha256"
