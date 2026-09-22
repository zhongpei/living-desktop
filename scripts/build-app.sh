#!/usr/bin/env bash
# 构建 LivingDesktop.app（可分发的 .app bundle）。
#
# 用法：scripts/build-app.sh [VERSION]
#   VERSION 缺省时自动推断：HEAD 上的精确标签（v0.2 → 0.2）；
#   标签之后的提交 → 「标签-偏移-g哈希」；不在 git 仓库里 → dev。
# 产物：dist/LivingDesktop.app
# LIVING_DESKTOP_CONTENT_MODE=external 时只打程序与内置规则，角色/组/剧情
# 由单独的内容 Release 提供；LIVING_DESKTOP_DIST 可指定隔离输出目录。
#
# bundle 组装流程改自 Hopet（MIT License, © 2026 BinaryFroggy）的
# scripts/build-release.sh，按 Living Desktop 裁剪：不做 DMG、不做 universal。
# ad-hoc 签名（无需 Apple Developer ID），使用稳定 designated requirement，
# 避免每次重编后因 CDHash 改变而被 macOS 当成新的权限主体。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
RESOURCE_ROOT="${LIVING_DESKTOP_RESOURCES:-$ROOT/Resources}"
CONTENT_MODE="${LIVING_DESKTOP_CONTENT_MODE:-bundled}"

if [ "$CONTENT_MODE" != bundled ] && [ "$CONTENT_MODE" != external ]; then
    echo "error: LIVING_DESKTOP_CONTENT_MODE 必须是 bundled 或 external" >&2
    exit 1
fi
if [ "$CONTENT_MODE" = bundled ] && [ ! -d "$RESOURCE_ROOT/petpack" ]; then
    echo "error: 发布构建需要角色资源；请设置 LIVING_DESKTOP_RESOURCES" >&2
    exit 1
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --exact-match 2>/dev/null || git describe --tags 2>/dev/null || echo dev)"
    VERSION="${VERSION#v}"
fi
BUNDLE_ID="com.zhongpei.livingdesktop"
APP_NAME="LivingDesktop"
DIST="${LIVING_DESKTOP_DIST:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"

echo "==> Living Desktop release build (version: $VERSION)"

echo "==> swift build -c release ($(uname -m))"
swift build -c release --product LivingDesktop
BUILT_DIR="$ROOT/.build/release"
BIN="$BUILT_DIR/LivingDesktop"
[ -x "$BIN" ] || { echo "error: 找不到构建产物 $BIN" >&2; exit 1; }

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod 0755 "$APP/Contents/MacOS/$APP_NAME"

# MLX 着色器库（本地大脑运行时依赖）：与 MyPet 二进制同目录（mlx backend
# 首选查找位）。SwiftPM 不产出它，必须自编（见 build-metallib.sh 头注释）。
bash "$SCRIPT_DIR/build-metallib.sh"
cp ".build/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"

# 应用图标与菜单栏托盘图（scripts/make_icons.py 产出，随仓库入库）。
if [ -f "$RESOURCE_ROOT/AppIcon.icns" ]; then
    cp "$RESOURCE_ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f "$RESOURCE_ROOT/tray-cat.png" ]; then
    cp "$RESOURCE_ROOT/tray-cat.png" "$APP/Contents/Resources/tray-cat.png"
fi

# 运行时目录全部按原结构入包。缺失目录由运行时既有降级路径处理。
for resource_dir in categories effects gameplay relationships; do
    if [ -d "$RESOURCE_ROOT/$resource_dir" ]; then
        cp -R "$RESOURCE_ROOT/$resource_dir" "$APP/Contents/Resources/$resource_dir"
    fi
done
if [ "$CONTENT_MODE" = bundled ]; then
    for resource_dir in packages petpack props castpacks stories castgroups characters; do
        if [ -d "$RESOURCE_ROOT/$resource_dir" ]; then
            cp -R "$RESOURCE_ROOT/$resource_dir" "$APP/Contents/Resources/$resource_dir"
        fi
    done
fi

# 行动脑模型（Needle 3）进包：缺失时自动下载一次（~34MB）。
# 模型不入 git；打上它，行动脑开箱即用。
MODEL_SRC="$RESOURCE_ROOT/needle3.cact"
if [ ! -f "$MODEL_SRC" ]; then
    bash "$SCRIPT_DIR/fetch_needle.sh" "$MODEL_SRC"
fi
echo "==> 打包行动脑模型（$(du -h "$MODEL_SRC" | cut -f1)）"
cp "$MODEL_SRC" "$APP/Contents/Resources/needle3.cact"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Living Desktop</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 zhongpei. MIT License.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - --timestamp=none \
    --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP"
codesign --verify --deep --strict "$APP"

echo
echo "==> 完成：$APP"
echo "    启动：open '$APP'"
