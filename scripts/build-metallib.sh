#!/usr/bin/env bash
# 编译 MLX 的 Metal 着色器库（mlx.metallib）。
#
# 背景：mlx-swift 的 SwiftPM 产物不含编译好的 metallib（SwiftPM 不编译 .metal），
# 运行时按「二进制同目录 → Resources/ → SwiftPM bundle」顺序查找（mlx backend
# device.cpp load_default_library）。swift run / swift test / .app 三种形态都
# 需要把本脚本产物放到对应位置：
#   - swift run / swift test：拷到 .build/< debug|release >/ 下（测试是 .xctest
#     bundle 时拷到 .xctest/Contents/MacOS/）
#   - .app：build-app.sh 拷到 Contents/MacOS/（与应用二进制同目录）
#
# 用法：scripts/build-metallib.sh [输出路径]
#   输出缺省为 .build/mlx.metallib；已是最新（比所有 .metal 源新）则跳过。
# 前提：包依赖已解析（.build/checkouts/mlx-swift 存在，缺则先 swift package resolve）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/mlx.metallib}"
CHECKOUT="$ROOT/.build/checkouts/mlx-swift"
GEN="$CHECKOUT/Source/Cmlx/mlx-generated/metal"
KDIR="$CHECKOUT/Source/Cmlx/mlx/mlx/backend/metal/kernels"

[ -d "$GEN" ] || { echo "error: 找不到 $GEN —— 先运行 swift package resolve" >&2; exit 1; }

if [ -f "$OUT" ] && [ -z "$(find "$GEN" -type f -name '*.metal' -newer "$OUT" -print -quit)" ]; then
    exit 0   # 已是最新
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

while IFS= read -r -d '' f; do
    # steel/attn/kernels/steel_attention.metal 也属于 mlx 的静态 kernel；
    # 只编译 generated/metal 顶层文件会漏掉它，运行到 attention 时才崩。
    xcrun metal -fno-fast-math -c "$f" -I "$GEN" -I "$KDIR" \
        -o "$TMP/$(basename "${f%.metal}").air"
done < <(find "$GEN" -type f -name '*.metal' -print0)
mkdir -p "$(dirname "$OUT")"
xcrun metallib "$TMP"/*.air -o "$OUT"
echo "mlx.metallib -> $OUT"
