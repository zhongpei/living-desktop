#!/usr/bin/env bash
# 下载 Needle 3 行动脑模型（needle3.cact，~34MB）。
# 模型不入 git；缺它时 app 自动降级为随机动作脑（菜单里会显示）。
#
# 用法：scripts/fetch_needle.sh [目标路径]
#   默认下载到 Resources/needle3.cact（swift run 自动发现）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/Resources/needle3.cact}"
URL="https://modelscope.cn/models/Cactus-Compute/needle3/resolve/master/needle3.cact"

if [ -f "$DEST" ]; then
    echo "==> 已存在：$DEST（删除后重跑可强制更新）"
    exit 0
fi

echo "==> 下载 Needle 3 模型 → $DEST"
mkdir -p "$(dirname "$DEST")"
curl -fL "$URL" -o "$DEST"
ls -la "$DEST"
echo "==> 完成。启动 Living Desktop 即启用行动脑（菜单里可关闭）。"
