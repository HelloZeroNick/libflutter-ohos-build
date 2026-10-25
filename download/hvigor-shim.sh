#!/bin/bash
# 生成一个可用的 hvigor 命令，替代 SDK 自带、但本 SDK 包中缺失的 hvigorw。
#
# 背景：
#   flutter 的 `engine/src/flutter/attachment/scripts/ohos_create_flutter_har.py`
#   在 BuildHar() 里硬编码调用 `hvigorw clean --mode module -p ... assembleHar`
#   （见 :75-79）。而 ErBWs/ohos-sdk 发布的命令行工具包中
#   `/sdk/command-line-tools/tools/` 整个目录都不存在，即没有 hvigorw，
#   ninja 该 action 直接 `sh: hvigorw: not found`（exit 127）。
#
# 做法：
#   用 npm 从华为 registry 装 `@ohos/hvigor` + `@ohos/hvigor-ohos-plugin`，
#   再在 $BIN_DIR 放一个同名 `hvigorw` 包装脚本。它把 HVIGOR_NODE_MODULES
#   挂进 NODE_PATH（hvigorfile.ts 里 `require('@ohos/hvigor-ohos-plugin')`
#   就从这里解析），然后直接交给 node 跑 hvigor 的 CLI 入口，
#   完全绕开 wrapper 的 pnpm 自举和 ~/.npmrc 依赖。
#
# 用法：
#   bash download/hvigor-shim.sh            # 默认装到 $ROOT/.hvigor-shim
#   BIN_DIR=/usr/local/bin bash download/hvigor-shim.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/download/deps-version.sh"

HVIGOR_HOME="${HVIGOR_HOME:-$ROOT/.hvigor-shim}"
BIN_DIR="${BIN_DIR:-$HVIGOR_HOME/bin}"

echo "=== hvigor 版本: $V_HVIGOR"
echo "=== 安装目录: $HVIGOR_HOME"

mkdir -p "$HVIGOR_HOME" "$BIN_DIR"

# 华为 registry 上只有 @ohos 这个 scope 全，其它包（postcss 等 peerDep）
# 走公共 npm；两个 registry 混用必须显式分 scope，否则 404。
cat > "$HVIGOR_HOME/.npmrc" <<EOF
@ohos:registry=https://repo.harmonyos.com/npm/
registry=https://registry.npmjs.org/
EOF

pushd "$HVIGOR_HOME" >/dev/null
if [ ! -x node_modules/@ohos/hvigor/bin/hvigor.js ]; then
  npm install --no-save --no-audit --no-fund \
    --userconfig "$HVIGOR_HOME/.npmrc" \
    "@ohos/hvigor@$V_HVIGOR" "@ohos/hvigor-ohos-plugin@$V_HVIGOR"
fi
popd >/dev/null

NODE_BIN="$(command -v node)"
echo "=== node: $NODE_BIN"

# 注意：hvigorfile.ts 在项目目录里 require 插件，Node 从项目目录往上找，
# 所以必须用 NODE_PATH 把安装目录暴露出去（不能只塞 node_modules 到项目里，
# 因为 ohos_create_flutter_har.py 会 copytree 出一个临时工程）。
cat > "$BIN_DIR/hvigorw" <<EOF
#!/bin/bash
export NODE_PATH="$HVIGOR_HOME/node_modules\${NODE_PATH:+:\$NODE_PATH}"
exec "$NODE_BIN" "$HVIGOR_HOME/node_modules/@ohos/hvigor/bin/hvigor.js" "\$@"
EOF
chmod +x "$BIN_DIR/hvigorw"

# ohos_create_flutter_har.py 在 apiInt != 11 时用的是裸 `hvigorw`，
# apiInt == 11 时用的是 `./hvigorw`（脚本按当前目录找）。两种都覆盖：
# 把 bin 目录加到 PATH，并在临时工程里放一个同名软链由 make_hars 前处理，
# 这里只保证 PATH 上能找到。
echo "=== hvigorw: $BIN_DIR/hvigorw"
"$BIN_DIR/hvigorw" --version
