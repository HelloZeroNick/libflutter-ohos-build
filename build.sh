#!/bin/bash
# 构建带 device-lost 补丁的 Flutter OHOS 引擎，产出应用可直接使用的 har。
#
# 用法：
#   ./build.sh                                  # 默认 oh-3.47.7-dev
#   ./build.sh oh-3.44.9-dev                    # 指定分支
#   USE_BISHENG=false ./build.sh oh-3.47.7-dev  # 退回 llvm 工具链
#   GN_EXTRA_PARAM=--lto ./build.sh             # 追加 gn 参数
#   BUILD_HOST=true ./build.sh                  # 额外构建 host 产物（gen_snapshot）
#
# 产物（out/<branch>/）：
#   flutter.har                      ohos.py 产出的完整 har
#   flutter_embedding_release.har    legacy hvigor 构建器需要
#   arm64_v8a_release.har            legacy hvigor 构建器需要
#   libflutter.so                    引擎动态库
#   SHA256SUMS / VERSION

set -euo pipefail

BRANCH="${1:-${FLUTTER_BRANCH:-oh-3.47.7-dev}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${SDK_ROOT:-/sdk}"
SDK_HOME="${DEVECO_SDK_HOME:-$SDK_ROOT/command-line-tools/sdk}"
WORK_ROOT="${WORK_ROOT:-$ROOT/work}"
CHECKOUT="$WORK_ROOT/$BRANCH"
OUT_DIR="$ROOT/out/$BRANCH"
DEPOT="$WORK_ROOT/depot_tools"

# 默认：release 模式、LTO 显式打开、启用 BiSheng 工具链
USE_BISHENG="${USE_BISHENG:-true}"
GN_EXTRA_PARAM="${GN_EXTRA_PARAM:---lto}"

mkdir -p "$OUT_DIR" "$WORK_ROOT"

echo "=== 分支: $BRANCH"
echo "=== 工作目录: $CHECKOUT"
echo "=== 产物目录: $OUT_DIR"

# ---------------------------------------------------------------------------
# 1. 找 OHOS NDK（必须同时具备 llvm/bin、sysroot、build-tools/cmake/bin）
# ---------------------------------------------------------------------------
find_ndk() {
  local root="$1"
  [ -d "$root" ] || return 1
  local cand
  while IFS= read -r cand; do
    if [ -d "$cand/llvm/bin" ] && [ -d "$cand/sysroot" ] && [ -d "$cand/build-tools/cmake/bin" ]; then
      echo "$cand"
      return 0
    fi
  done < <(find "$root" -maxdepth 5 -type d -name native 2>/dev/null | sort -r)
  return 1
}

NDK_HOME="${OHOS_NDK_HOME:-}"
if [ -n "$NDK_HOME" ] && [ ! -d "$NDK_HOME/llvm/bin" ]; then
  echo "=== OHOS_NDK_HOME=$NDK_HOME 不是有效 NDK，改为自动探测"
  NDK_HOME=""
fi
if [ -z "$NDK_HOME" ]; then
  NDK_HOME="$(find_ndk "$SDK_HOME" || true)"
fi
if [ -z "$NDK_HOME" ]; then
  echo "!! 在 $SDK_HOME 下找不到可用的 NDK（需要 llvm/、sysroot/、build-tools/cmake/）" >&2
  find "$SDK_HOME" -maxdepth 4 -type d -name native 2>/dev/null >&2 || true
  exit 1
fi

export DEVECO_SDK_HOME="$SDK_HOME"
export OHOS_NDK_HOME="$NDK_HOME"
export PATH="$SDK_ROOT/command-line-tools/tools/ohpm/bin:$SDK_ROOT/command-line-tools/tools/hvigor/bin:$SDK_ROOT/command-line-tools/tools/node/bin:$NDK_HOME/build-tools/cmake/bin:$PATH"

echo "=== DEVECO_SDK_HOME=$DEVECO_SDK_HOME"
echo "=== OHOS_NDK_HOME=$OHOS_NDK_HOME"

# ---------------------------------------------------------------------------
# 2. 工具链：优先 BiSheng（ohos.py 默认），缺失时可显式退回 llvm
# ---------------------------------------------------------------------------
BISHENG_HOME="$(cd "$NDK_HOME/../.." && pwd)/hms/native/BiSheng"
BISHENG_FLAG=""
if [ "$USE_BISHENG" = "true" ]; then
  if [ -x "$BISHENG_HOME/bin/clang" ] || [ -x "$BISHENG_HOME/llvm/bin/clang" ]; then
    echo "=== 工具链: BiSheng ($BISHENG_HOME)"
  else
    echo "!! 找不到 BiSheng 编译器: $BISHENG_HOME" >&2
    echo "   如需退回 llvm，请设置 USE_BISHENG=false" >&2
    ls -la "$(dirname "$BISHENG_HOME")" 2>/dev/null >&2 || true
    exit 1
  fi
else
  echo "=== 工具链: llvm（USE_BISHENG=false）"
  BISHENG_FLAG="--unuse-bisheng"
fi

# ---------------------------------------------------------------------------
# 3. depot_tools（gclient / vpython3 / gn）
# ---------------------------------------------------------------------------
if [ ! -d "$DEPOT" ]; then
  echo "=== 下载 depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT"
fi
export PATH="$DEPOT:$PATH"
export DEPOT_TOOLS_UPDATE=0

# ---------------------------------------------------------------------------
# 4. gclient 拉取源码（flutter_flutter 仓库根 + DEPS_ohos 依赖）
# ---------------------------------------------------------------------------
mkdir -p "$CHECKOUT"
cd "$CHECKOUT"

if [ ! -d engine/src/flutter/impeller ]; then
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
# 5. 打补丁
# ---------------------------------------------------------------------------
python3 "$ROOT/scripts/apply_patch.py" "$CHECKOUT/engine/src/flutter"

# ---------------------------------------------------------------------------
# 6. 编译
# ---------------------------------------------------------------------------
cd "$CHECKOUT/engine"
chmod +x ohos || true
# ohos.py 把 <engine>/depot_tools 加进 PATH，这里补一个软链指向 DEPS 拉下来的那份
if [ ! -e depot_tools ] && [ -d src/flutter/third_party/depot_tools ]; then
  ln -sfn src/flutter/third_party/depot_tools depot_tools
fi

ARGS=(-n config compile har -t release --ohos-cpu arm64)
if [ -n "$GN_EXTRA_PARAM" ]; then
  # ohos.py 的参数是 nargs='?'，必须用「紧贴」写法，否则 --lto 会被当成未知选项：
  #   ✅ -g=--lto / -g--lto     ❌ -g --lto
  ARGS+=("-g=$GN_EXTRA_PARAM")
fi
if [ -n "$BISHENG_FLAG" ]; then
  ARGS+=("$BISHENG_FLAG")
fi
if [ "${BUILD_HOST:-false}" = "true" ]; then
  ARGS+=(-n host)
fi

OUT_ENGINE="$CHECKOUT/engine/src/out/ohos_release_arm64"

echo "=== 开始编译: ./ohos ${ARGS[*]}"
./ohos "${ARGS[@]}"

if [ -f "$OUT_ENGINE/args.gn" ]; then
  echo "=== args.gn 关键项"
  grep -E "^(enable_lto|is_debug|is_official_build|optimize_for_size|target_toolchain|target_triple|is_component_build) " "$OUT_ENGINE/args.gn" || true
fi

if [ ! -f "$OUT_ENGINE/flutter.har" ]; then
  echo "!! 没有产出 flutter.har: $OUT_ENGINE" >&2
  ls -la "$OUT_ENGINE" || true
  exit 1
fi

# ---------------------------------------------------------------------------
# 7. 收集产物
# ---------------------------------------------------------------------------
cp -f "$OUT_ENGINE/flutter.har" "$OUT_DIR/flutter.har"
if [ -f "$OUT_ENGINE/libflutter.so" ]; then
  cp -f "$OUT_ENGINE/libflutter.so" "$OUT_DIR/libflutter.so"
fi
ENGINE_SHA="$(git -C "$CHECKOUT/engine/src/flutter" rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf '%s %s bisheng=%s gn_extra=%s\n' "$BRANCH" "$ENGINE_SHA" "$USE_BISHENG" "$GN_EXTRA_PARAM" > "$OUT_DIR/VERSION"
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
