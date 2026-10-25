# libflutter-ohos-build

在 GitHub Actions 上构建 **带 device-lost 补丁** 的 Flutter OHOS 引擎，产出应用（legacy hvigor 构建器）
可以直接使用的两个 har。

## 为什么需要这个补丁

OHOS 上 Impeller 走 Vulkan（`enable_impeller=true`）。`FenceWaiterVK` 的等待线程一旦等到
非 `eSuccess`/`eTimeout` 的结果（典型是 `VK_ERROR_DEVICE_LOST`）就**永久退出**，但
`FenceWaiterVK::AddFence()` 之后仍然每帧接受新 fence：

* 命令缓冲 / 交换链图像再也没人回收；
* Maleoon 驱动在 device lost 之后被反复调用还会继续分配显存；
* 于是 GL 显存以 ~100–200 MB/s 增长，最终被系统 `StabilityCheckKill`（进程 signal 9）杀掉，
  表现为「上屏阶段偶发卡顿 + 低概率闪退」，faultlog 里查不到崩溃。

补丁（`scripts/apply_patch.py`，三个文件）：

| 文件 | 改动 |
| --- | --- |
| `impeller/renderer/backend/vulkan/fence_waiter_vk.h` | 新增 `IsDeviceLost()` 与 `std::atomic<bool> device_lost_{false}` |
| `impeller/renderer/backend/vulkan/fence_waiter_vk.cc` | 等待失败时置位 `device_lost_` 并打印具体 `vk::Result`；`AddFence()` 在 device lost 后拒绝再提交 |
| `impeller/renderer/backend/vulkan/surface_context_vk.cc` | device lost 后 `AcquireNextSurface()` 直接返回 `nullptr`，不再反复戳驱动 |

3.44.x 与 3.47.x 两代源码都能直接打（`AddFence` 返回 `bool` / `fml::Status` 的差异已处理），
脚本可重复执行。

## 产物（每个分支一份）

| 文件 | 用途 |
| --- | --- |
| `flutter.har` | `ohos.py` 原始输出（合并版：embedding + so） |
| `flutter_embedding_release.har` | `@ohos/flutter_ohos` 依赖，放到 `bin/cache/artifacts/engine/ohos-arm64-release/` |
| `arm64_v8a_release.har` | `flutter_native_arm64_v8a` 依赖，同目录 |
| `libflutter.so` | 引擎动态库 |
| `SHA256SUMS` / `VERSION` | 校验与版本标记 |

`make_hars.py` 从合并版拆分：embedding har 去掉 `libs/` 下的文件；native har 按官方预编译产物的
骨架逐字节重建（已与官方 har 对比过文件列表与 metadata）。

## 本地使用

```bash
# 1. 下载 release 里的文件，放到
#    <flutter>/bin/cache/artifacts/engine/ohos-arm64-release/
#    （flutter_embedding_release.har、arm64_v8a_release.har、libflutter.so）

# 2. 清掉旧引擎缓存，让应用重新链接
rm -rf <app>/ohos/entry/build <app>/build

# 3. 重新构建应用
flutter build hap --release
```

## 手动构建

```bash
./build.sh oh-3.47.7-dev                 # 单分支
BUILD_HOST=true ./build.sh oh-3.44.9-dev # 额外构建 host 产物
```

需要：Ubuntu、`git`、`python3`、`ninja`、能访问 gitcode.com 的网络，以及
`download/download-sdk.sh` 装好的 HarmonyOS SDK（`/sdk/command-line-tools`）。

首次会 `gclient sync` 拉取 `flutter_flutter` 及其全部 DEPS（较慢，约 10–20 分钟），
之后编译 release 引擎。
