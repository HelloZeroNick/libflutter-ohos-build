#!/usr/bin/env python3
"""把 ohos.py 产出的完整 flutter.har 拆成应用需要的两个 har。

`./ohos -n har` 只产出「合并版」flutter.har（embedding 源码 + libs/arm64-v8a/libflutter.so）。
而应用侧 legacy hvigor 构建器（packages/flutter_tools/lib/src/ohos/hvigor.dart:321-328）
需要同一目录下同时存在：

    flutter_embedding_<mode>.har    # @ohos/flutter_ohos
    <arch>_<mode>.har               # flutter_native_arm64_v8a（只放 so）

本脚本从合并版拆出这两个文件：

* embedding har = 合并版去掉 package/libs/**下的文件（保留空目录，与官方产物一致）
* native har    = 官方预编译产物是 hvigor 构建出来的，这里按同样的骨架重建
                  （官方 har 的 metadata 已逐字比对过），只装 libs/<arch>/libflutter.so

用法：
    make_hars.py <flutter.har> <out_dir> [--mode release] [--arch arm64-v8a]
                 [--version <git short sha>]
"""
import argparse
import io
import json
import os
import sys
import tarfile

LIB_PREFIX = "package/libs/"

NATIVE_HVIGORFILE = """import { harTasks } from '@ohos/hvigor-ohos-plugin';

export default {
    system: harTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[]         /* Custom plugin to extend the functionality of Hvigor. */
}
"""

NATIVE_BUILD_PROFILE = """{
  "apiType": "stageMode",
  "buildOption": {
    "nativeLib": {
      "debugSymbol": {
        "strip": false,
        "exclude": []
      }
    }
  },
  "buildOptionSet": [
    {
      "name": "release",
      "arkOptions": {
        "obfuscation": {
          "ruleOptions": {
            "enable": false,
            "files": [
              "./obfuscation-rules.txt"
            ]
          },
          "consumerFiles": [
            "./consumer-rules.txt"
          ]
        }
      },
    },
  ],
  "targets": [
    {
      "name": "default"
    }
  ]
}
"""

NATIVE_OBFUSCATION_RULES = """# Define project specific obfuscation rules here.
# You can include the obfuscation configuration files in the current module's build-profile.json5.
#
# For more details, see
#   https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/source-obfuscation-V5

# Obfuscation options:
# -disable-obfuscation: disable all obfuscations
# -enable-property-obfuscation: obfuscate the property names
# -enable-toplevel-obfuscation: obfuscate the names in the global scope
# -compact: remove unnecessary blank spaces and all line feeds
# -remove-log: remove all console.* statements
# -print-namecache: print the name cache that contains the mapping from the old names to new names
# -apply-namecache: reuse the given cache file

# Keep options:
# -keep-property-name: specifies property names that you want to keep
# -keep-global-name: specifies names that you want to keep in the global scope

-enable-property-obfuscation
-enable-toplevel-obfuscation
-enable-filename-obfuscation
-enable-export-obfuscation"""

NATIVE_BUILD_PROFILE_ETS = """/**
 * Use these variables when you tailor your ArkTS code. They must be of the const type.
 */
export const HAR_VERSION = '{version}';
export const BUILD_MODE_NAME = '{mode}';
export const DEBUG = {debug};
export const TARGET_NAME = 'default';

/**
 * BuildProfile Class is used only for compatibility purposes.
 */
export default class BuildProfile {{ 
\tstatic readonly HAR_VERSION = HAR_VERSION;
\tstatic readonly BUILD_MODE_NAME = BUILD_MODE_NAME;
\tstatic readonly DEBUG = DEBUG;
\tstatic readonly TARGET_NAME = TARGET_NAME;
}}"""

NATIVE_OH_PACKAGE = {
    "name": "flutter_native_arm64_v8a",
    "version": "1.0.0",
    "description": "Place so files for flutter on ohos.",
    "main": "Index.ets",
    "author": "",
    "license": "Apache-2.0",
    "dependencies": {},
    "metadata": {
        "sourceRoots": ["./src/main"],
        "debug": False,
        "nativeDebugSymbol": False,
    },
    "dependencyMode": "loose",
    "compatibleSdkVersionStage": "beta1",
    "compatibleSdkVersion": 12,
    "compatibleSdkType": "HarmonyOS",
    "obfuscated": False,
}


def read_members(har_path):
    members = []
    with tarfile.open(har_path, "r:gz") as tar:
        for info in tar.getmembers():
            data = None
            if info.isfile():
                f = tar.extractfile(info)
                data = f.read() if f else b""
            members.append((info, data))
    return members


def write_har(path, entries):
    """entries: list of (name, bytes|None, mode|None)；bytes 为 None 表示目录。"""
    with tarfile.open(path, "w:gz") as tar:
        for name, data, mode in entries:
            info = tarfile.TarInfo(name)
            if data is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            else:
                info.size = len(data)
                info.mode = mode or 0o644
                tar.addfile(info, io.BytesIO(data))


def split_embedding(members, out_path):
    entries = []
    dropped = 0
    for info, data in members:
        # 官方 embedding har 保留空的 package/libs/ 目录，但不含任何文件
        if info.name == LIB_PREFIX and info.isdir():
            entries.append((info.name, None, None))
            continue
        if info.name.startswith(LIB_PREFIX):
            dropped += 1
            continue
        entries.append((info.name, data, info.mode if info.isfile() else None))
    write_har(out_path, entries)
    return dropped


def build_native(members, out_path, version, arch, mode):
    by_name = {info.name: data for info, data in members}
    module_json = by_name.get("package/src/main/module.json")
    if module_json:
        try:
            mj = json.loads(module_json.decode("utf-8"))
            mod = mj.setdefault("module", {})
            mod["name"] = "flutter_native"
            mod["type"] = "har"
            mod["packageName"] = "flutter_native_arm64_v8a"
            mod["deviceTypes"] = ["default"]
            mod["dependencies"] = []
            module_json = (
                json.dumps(mj, ensure_ascii=False, indent="\t") + "\n"
            ).encode("utf-8")
        except Exception as exc:  # noqa: BLE001
            print(f"[warn] module.json 解析失败，原样使用: {exc}")

    oh_package = dict(NATIVE_OH_PACKAGE)
    oh_package["version"] = f"1.0.0-{version}" if version else "1.0.0"

    build_profile_ets = NATIVE_BUILD_PROFILE_ETS.format(
        version=oh_package["version"],
        mode=mode,
        debug="true" if mode != "release" else "false",
    ).encode("utf-8")

    lib = by_name.get(f"package/libs/{arch}/libflutter.so")
    if lib is None:
        print(f"[error] 合并版 har 里没有 package/libs/{arch}/libflutter.so")
        return False

    entries = [
        ("package/BuildProfile.ets", build_profile_ets, None),
        ("package/Index.ets", b"", None),
        ("package/build-profile.json5", NATIVE_BUILD_PROFILE.encode("utf-8"), None),
        ("package/consumer-rules.txt", b"", None),
        ("package/hvigorfile.ts", NATIVE_HVIGORFILE.encode("utf-8"), None),
        ("package/obfuscation-rules.txt", NATIVE_OBFUSCATION_RULES.encode("utf-8"), None),
        ("package/obfuscation.txt", b"", None),
        (
            "package/oh-package.json5",
            (json.dumps(oh_package, ensure_ascii=False) + "\n").encode("utf-8"),
            None,
        ),
        ("package/src/", None, None),
        ("package/src/main/", None, None),
        ("package/src/main/module.json", module_json or b"{}\n", None),
        ("package/libs/", None, None),
        (f"package/libs/{arch}/", None, None),
        (f"package/libs/{arch}/libflutter.so", lib, None),
    ]
    write_har(out_path, entries)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("har")
    ap.add_argument("out_dir")
    ap.add_argument("--mode", default="release")
    ap.add_argument("--arch", default="arm64-v8a")
    ap.add_argument("--version", default="")
    args = ap.parse_args()

    if not os.path.isfile(args.har):
        print(f"[error] 找不到 {args.har}")
        return 1
    os.makedirs(args.out_dir, exist_ok=True)

    members = read_members(args.har)
    print(f"合并版 har 包含 {len(members)} 个成员")

    emb = os.path.join(args.out_dir, f"flutter_embedding_{args.mode}.har")
    native = os.path.join(args.out_dir, f"{args.arch.replace('-', '_')}_{args.mode}.har")

    dropped = split_embedding(members, emb)
    print(f"[ok] {emb}（丢弃 libs 下 {dropped} 个文件）")

    if not build_native(members, native, args.version, args.arch, args.mode):
        return 1
    print(f"[ok] {native}")

    for p in (emb, native):
        print(f"    {os.path.basename(p)}: {os.path.getsize(p)} 字节")
    return 0


if __name__ == "__main__":
    sys.exit(main())
