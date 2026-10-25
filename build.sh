#!/bin/bash
# 构建带 device-lost 补丁的 Flutter OHOS 引擎，产出应用可直接使用的 har。
#
# 用法：
#   ./build.sh                                  # 默认 oh-3.47.7-dev
#   ./build.sh oh-3.44.9-dev                    # 指定分支
#   BUILD_HOST=true ./build.sh oh-3.47.7-dev    # 额外构建 host 产物（gen_snapshot）
#
# 产物（out/<branch>/）：
#   flutter.har                      ohos.py 产出的完整 har
#   flutter_embedding_release.har    legacy hvigor 构建器需要
#   arm64_v8a_release.har            legacy hvigor 构建器需要
#   libflutter.so                    引擎动态库
#   SHA256SUMS

set -euo pipefail

BRANCH="${1:-${FLUTTER_BRANCH:-oh-3.47.7-dev}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-/sdk}"
SDK_HOME="$SDK_ROOT/command-line-tools/sdk"
NDK_HOME="${OHOS_NDK_HOME:-$SDK_HOME/default/openharmony}"
WORK_ROOT="${WORK_ROOT:-$ROOT/work}"
CHECKOUT="$WORK_ROOT/$BRANCH"
OUT_DIR="$ROOT/out/$BRANCH"
DEPOT="$WORK_ROOT/depot_tools"

mkdir -p "$OUT_DIR" "$WORK_ROOT"

echo "=== 分支: $BRANCH"
echo "=== 工作目录: $CHECKOUT"
echo "=== 产物目录: $OUT_DIR"

# ---------------------------------------------------------------------------
# 1. 环境变量
# ---------------------------------------------------------------------------
export DEVECO_SDK_HOME="$SDK_HOME"
export OHOS_NDK_HOME="$NDK_HOME"
export PATH="$SDK_ROOT/command-line-tools/tools/ohpm/bin:$SDK_ROOT/command-line-tools/tools/hvigor/bin:$SDK_ROOT/command-line-tools/tools/node/bin:$NDK_HOME/build-tools/cmake/bin:$PATH"

if [ ! -d "$NDK_HOME" ]; then
  echo "!! 找不到 OHOS NDK: $NDK_HOME（先执行 download/download-sdk.sh）" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. depot_tools（gclient / vpython3 / gn）
# ---------------------------------------------------------------------------
if [ ! -d "$DEPOT" ]; then
  echo "=== 下载 depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT"
fi
export PATH="$DEPOT:$PATH"
export DEPOT_TOOLS_UPDATE=0

# ---------------------------------------------------------------------------
# 3. gclient 拉取源码（flutter_flutter 仓库根 + DEPS_ohos 依赖）
# ---------------------------------------------------------------------------
mkdir -p "$CHECKOUT"
cd "$CHECKOUT"

if [ ! -d engine/src/flutter/.git ] && [ ! -f engine/src/flutter/DEPS ]; then
  echo "=== gclient 配置 ($BRANCH)"
  cat > .gclient <<EOF
solutions = [
  {
    "managed": False,
    "name": ".",
    "url": "https://gitcode.com/openharmony-tpc/flutter_flutter.git@$BRANCH",
    "custom_deps": {},
    "deps_file": "DEPS_ohos",
    "safesync_url": "",
    "custom_vars": { "download_emsdk": False },
  },
]
EOF
  echo "=== gclient sync（首次较慢）"
  gclient sync --no-history -D --shallow --jobs 8
else
  echo "=== 已有源码，跳过 gclient sync"
fi

if [ ! -d engine/src/flutter/impeller ]; then
  echo "!! 源码目录不完整: $CHECKOUT/engine/src/flutter/impeller" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. 打补丁
# ---------------------------------------------------------------------------
python3 "$ROOT/scripts/apply_patch.py" "$CHECKOUT/engine/src/flutter"

# ---------------------------------------------------------------------------
# 5. 编译
# ---------------------------------------------------------------------------
cd "$CHECKOUT/engine"
chmod +x ohos || true
# ohos.py 把 <engine>/depot_tools 加进 PATH，这里补一个软链指向 DEPS 拉下来的那份
if [ ! -e depot_tools ] && [ -d src/flutter/third_party/depot_tools ]; then
  ln -sfn src/flutter/third_party/depot_tools depot_tools
fi

TYPES="release"
NAMES="config compile har"
if [ "${BUILD_HOST:-false}" = "true" ]; then
  NAMES="$NAMES host"
fi

echo "=== 开始编译: types=$TYPES names=$NAMES"
./ohos -n $NAMES -t $TYPES --verbose || ./ohos -n $NAMES -t $TYPES

OUT_ENGINE="$CHECKOUT/engine/src/out/ohos_release_arm64"
if [ ! -f "$OUT_ENGINE/flutter.har" ]; then
  echo "!! 没有产出 flutter.har: $OUT_ENGINE" >&2
  ls -la "$OUT_ENGINE" || true
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. 收集产物
# ---------------------------------------------------------------------------
cp -f "$OUT_ENGINE/flutter.har" "$OUT_DIR/flutter.har"
if [ -f "$OUT_ENGINE/libflutter.so" ]; then
  cp -f "$OUT_ENGINE/libflutter.so" "$OUT_DIR/libflutter.so"
fi
ENGINE_SHA="$(git -C "$CHECKOUT/engine/src/flutter" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "$BRANCH $ENGINE_SHA" > "$OUT_DIR/VERSION"
python3 "$ROOT/scripts/make_hars.py" "$OUT_DIR/flutter.har" "$OUT_DIR" \
  --mode release --arch arm64-v8a --version "$ENGINE_SHA"

if [ "${BUILD_HOST:-false}" = "true" ] && [ -d "$CHECKOUT/engine/src/out/host_release" ]; then
  tar -czf "$OUT_DIR/host_release.tar.gz" -C "$CHECKOUT/engine/src/out/host_release" .
fi

cd "$OUT_DIR"
sha256sum ./*.har > SHA256SUMS 2>/dev/null || true
[ -f libflutter.so ] && sha256sum libflutter.so >> SHA256SUMS || true

echo "=== 完成，产物："
ls -l "$OUT_DIR"
