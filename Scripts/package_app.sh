#!/bin/bash
# 将 SwiftPM 产物组装为可双击运行的 macOS 应用包。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FTPServer"
DISPLAY_NAME="FTP Server"
BUNDLE_ID="com.zdx8.ftpserver"
VERSION="1.0.0"
# 每次打包递增构建号。macOS 的应用图标缓存以「bundle 标识 + 版本号 + 路径」为键，
# 版本号不变时系统会一直沿用缓存中的旧图标——改了 AppIcon.icns 也不生效。
# 默认用时间戳保证单调变化，可用环境变量显式覆盖。
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d.%H%M)}"

echo "==> 编译 release 版本"
# UNIVERSAL=1 时同时编译 arm64 与 x86_64 并合成通用二进制，
# 让发布包在 Apple Silicon 与 Intel 机器上都能直接运行。
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "    目标架构：arm64 + x86_64（通用二进制）"
else
  ARCH_FLAGS=()
  echo "    目标架构：$(uname -m)"
fi
# 注意 ${ARCH_FLAGS[@]+...} 的写法：macOS 自带 bash 3.2，
# 在 set -u 下直接展开空数组会报 "unbound variable" 而中止打包。
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --disable-sandbox
BIN_PATH="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path --disable-sandbox)"

echo "==> 准备图标"
mkdir -p Resources
# 图标脚本比产物新时也要重新生成，避免改了图标却仍在复用旧文件
if [ ! -f "Resources/AppIcon.icns" ] || [ "Scripts/make_icon.swift" -nt "Resources/AppIcon.icns" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swiftc -O -o /tmp/ftpserver-make-icon Scripts/make_icon.swift
  /tmp/ftpserver-make-icon "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  echo "    已生成 Resources/AppIcon.icns"
else
  echo "    复用已有 Resources/AppIcon.icns（脚本未变更）"
fi

echo "==> 组装 .app"
APP_DIR="dist/${APP_NAME}.app"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

# 覆盖写入而非删除重建：避免批量删除被安全护栏拦截
cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>FTP Server 需要接受来自局域网设备的连接，以便提供文件传输服务。</string>
</dict>
</plist>
PLIST

echo "==> 临时签名"
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
  echo "    签名跳过（不影响本机运行）"

echo "==> 刷新系统图标与启动服务缓存"
# 触碰 bundle 更新时间戳，并让 LaunchServices 重新登记，
# 否则访达与 Dock 会继续展示缓存中的旧图标。
touch "${APP_DIR}"
touch "${APP_DIR}/Contents/Resources/AppIcon.icns"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
  "${LSREGISTER}" -f "${APP_DIR}" >/dev/null 2>&1 && echo "    已重新登记到 LaunchServices"
fi

if [ "${SKIP_ICON_CACHE_REFRESH:-0}" != "1" ]; then
  # Dock 与访达各自持有图标缓存，必须重启才会重读；
  # 两者重启是安全操作，Dock 会短暂消失后自动恢复。
  killall Dock 2>/dev/null && echo "    已重启 Dock（重新读取图标）" || echo "    Dock 未运行或无法重启"
  killall Finder 2>/dev/null && echo "    已重启访达（重新读取图标）" || echo "    访达未运行或无法重启"
  killall iconservicesagent 2>/dev/null && echo "    已重启图标服务" || true
else
  echo "    已跳过（SKIP_ICON_CACHE_REFRESH=1）"
fi

echo "==> 完成"
echo "    应用路径：$(pwd)/${APP_DIR}"
echo "    版本：${VERSION}（构建 ${BUILD_NUMBER}）"
echo "    体积：$(du -sh "${APP_DIR}" | cut -f1)"
