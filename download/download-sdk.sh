#!/bin/bash

set -eu

. ./download/deps-version.sh

# HarmonyOS command line tools (API $V_SDK, 含 BiSheng 编译器)
# 来源: https://github.com/ErBWs/ohos-sdk/releases/tag/$V_SDK
RELEASE_BASE=https://github.com/ErBWs/ohos-sdk/releases/download/$V_SDK
FILENAME=ohos-sdk-linux-amd64.tar.gz

sudo mkdir -p /sdk

pushd /sdk

if [ ! -d command-line-tools ]; then
  echo "Downloading HarmonyOS SDK $V_SDK ..."
  sudo wget -qO $FILENAME.aa $RELEASE_BASE/$FILENAME.aa
  sudo wget -qO $FILENAME.ab $RELEASE_BASE/$FILENAME.ab
  sudo wget -qO $FILENAME.sha256 $RELEASE_BASE/$FILENAME.sha256

  # 合并分片并校验
  sudo bash -c "cat $FILENAME.aa $FILENAME.ab > $FILENAME"
  sudo sha256sum -c $FILENAME.sha256

  sudo tar -xzf $FILENAME
  sudo rm -f $FILENAME.aa $FILENAME.ab $FILENAME.sha256 $FILENAME
fi

# 兼容链接: /sdk/linux -> openharmony (旧脚本路径)
if [ ! -e /sdk/linux ]; then
  sudo ln -sfn /sdk/command-line-tools/sdk/default/openharmony /sdk/linux
fi

# BiSheng 编译器链接
if [ ! -e /sdk/bisheng ]; then
  sudo ln -sfn /sdk/command-line-tools/sdk/default/hms/native/BiSheng /sdk/bisheng
fi

popd
