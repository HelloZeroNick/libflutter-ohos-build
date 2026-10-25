#!/usr/bin/env python3
"""给 flutter_flutter 的 Impeller Vulkan 后端打 device-lost 补丁。

背景：OHOS 上 Impeller 的 FenceWaiterVK 线程一旦等到非 eSuccess/eTimeout
（典型是 VK_ERROR_DEVICE_LOST）就永久退出，但 AddFence() 仍然每帧接受新 fence，
导致命令缓冲/交换链图像无限堆积，显存持续增长，最终被系统
StabilityCheckKill / GPU_LEAK_KILL 杀掉进程。

补丁做两件事：
1. 记录 device_lost_ 状态，一旦置位 AddFence() 拒绝再提交；
2. SurfaceContextVK::AcquireNextSurface() 在 device lost 后直接返回 nullptr，
   不再反复戳驱动（Maleoon 驱动在 device lost 后重复调用会持续分配显存）。

脚本对 3.44.x / 3.47.x 两代源码都适用（AddFence 的返回类型不同：bool / fml::Status，
只替换两边共有的 `if (terminate_) {` 条件行）。
所有替换都做「是否已打」判断，可重复执行。
"""
import os
import sys

MARK = "device_lost_"

ADD_FENCE_COMMENT = """      // Never accept work once the waiter is gone. Submitting here would queue
      // GPU work that nothing ever retires (the waiter thread is dead), which
      // makes graphics memory grow without bound until the process is killed.
"""

WAIT_BRANCH = '''  if (!(result == vk::Result::eSuccess || result == vk::Result::eTimeout)) {
    // This is almost always VK_ERROR_DEVICE_LOST. The waiter can never make
    // progress again, so flag the device as lost: AddFence() then stops
    // submitting work (otherwise command buffers, swapchain images and fences
    // pile up for a device that will never retire them).
    VALIDATION_LOG << "Fence waiter encountered an unexpected error ("
                   << vk::to_string(result)
                   << "). The Vulkan device is considered lost; tearing down "
                      "the waiter thread and refusing further submissions.";
    device_lost_.store(true);
    return false;
  }
'''

ACQUIRE_GUARD = """  // Once the Vulkan device is lost every driver call on this context fails, and
  // on some drivers (for example the OHOS Maleoon driver) repeatedly retrying
  // makes graphics memory grow until the process is killed by the system. Stop
  // poking the driver and simply skip frames instead.
  if (auto fence_waiter = parent_->GetFenceWaiter()) {
    if (fence_waiter->IsDeviceLost()) {
      return nullptr;
    }
  }
"""


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def patch_header(path):
    src = read(path)
    if MARK in src:
        print(f"[skip] {path} already patched")
        return True
    orig = src

    # 1) 声明 IsDeviceLost()
    anchor = "\n  void Terminate();\n"
    if anchor not in src:
        print(f"[error] anchor 'void Terminate();' not found in {path}")
        return False
    decl = (
        "\n  /// @brief Whether the waiter thread had to be torn down because a wait"
        "\n  ///        failed fatally (typically VK_ERROR_DEVICE_LOST). Once this"
        "\n  ///        returns true no further fences are accepted."
        "\n  bool IsDeviceLost() const { return device_lost_.load(); }\n"
    )
    src = src.replace(anchor, anchor + decl, 1)

    # 2) 成员变量
    anchor = "\n  bool terminate_ = false;\n"
    if anchor not in src:
        print(f"[error] anchor 'bool terminate_ = false;' not found in {path}")
        return False
    member = (
        "\n  // Set once when a wait fails fatally (usually VK_ERROR_DEVICE_LOST)."
        "\n  // Unlike [terminate_] this is never cleared; the Vulkan device cannot"
        "\n  // be recovered."
        "\n  std::atomic<bool> device_lost_{false};\n"
    )
    src = src.replace(anchor, anchor + member, 1)

    # 3) 需要 <atomic>
    if "#include <atomic>" not in src:
        src = src.replace("#include <mutex>", "#include <atomic>\n#include <mutex>", 1)

    if src == orig:
        print(f"[error] nothing changed in {path}")
        return False
    write(path, src)
    print(f"[ok] patched {path}")
    return True


def patch_impl(path):
    src = read(path)
    orig = src

    # 1) AddFence 拒绝新提交（bool / fml::Status 两代都只改条件行）
    anchor = "    if (terminate_) {\n"
    if MARK not in src:
        if anchor not in src:
            print(f"[error] anchor 'if (terminate_) {'{'}' not found in {path}")
            return False
        src = src.replace(anchor, "    if (terminate_ || device_lost_.load()) {\n" + ADD_FENCE_COMMENT, 1)
    else:
        print(f"[skip] AddFence already patched in {path}")

    # 2) Wait() 失败分支：置位 device_lost_
    if "device_lost_.store(true);" not in src:
        start = src.find("if (!(result == vk::Result::eSuccess || result == vk::Result::eTimeout)) {")
        if start < 0:
            print(f"[error] Wait() failure branch not found in {path}")
            return False
        # 找到该 if 块的结尾（"    return false;\n  }\n"）
        end = src.find("    return false;\n  }\n", start)
        if end < 0:
            print(f"[error] Wait() failure branch end not found in {path}")
            return False
        end += len("    return false;\n  }\n")
        src = src[:start] + WAIT_BRANCH + src[end:]

    if src == orig:
        print(f"[error] nothing changed in {path}")
        return False
    write(path, src)
    print(f"[ok] patched {path}")
    return True


def patch_surface_context(path):
    src = read(path)
    if "IsDeviceLost()" in src:
        print(f"[skip] {path} already patched")
        return True
    orig = src

    if "fence_waiter_vk.h" not in src:
        anchor = '#include "impeller/renderer/backend/vulkan/context_vk.h"\n'
        if anchor not in src:
            print(f"[error] include anchor not found in {path}")
            return False
        src = src.replace(
            anchor,
            anchor + '#include "impeller/renderer/backend/vulkan/fence_waiter_vk.h"\n',
            1,
        )

    anchor = "std::unique_ptr<Surface> SurfaceContextVK::AcquireNextSurface() {\n"
    if anchor not in src:
        print(f"[error] AcquireNextSurface not found in {path}")
        return False
    # 插在 TRACE_EVENT0 之后（若存在）
    trace = '  TRACE_EVENT0("impeller", __FUNCTION__);\n'
    if anchor + trace in src:
        src = src.replace(anchor + trace, anchor + trace + ACQUIRE_GUARD, 1)
    else:
        src = src.replace(anchor, anchor + ACQUIRE_GUARD, 1)

    if src == orig:
        print(f"[error] nothing changed in {path}")
        return False
    write(path, src)
    print(f"[ok] patched {path}")
    return True


def main():
    if len(sys.argv) != 2:
        print("usage: apply_patch.py <path/to/flutter_flutter/engine/src/flutter>")
        return 2
    flutter_src = os.path.abspath(sys.argv[1])
    vulkan = os.path.join(flutter_src, "impeller", "renderer", "backend", "vulkan")
    targets = [
        (patch_header, os.path.join(vulkan, "fence_waiter_vk.h")),
        (patch_impl, os.path.join(vulkan, "fence_waiter_vk.cc")),
        (patch_surface_context, os.path.join(vulkan, "surface_context_vk.cc")),
    ]
    for fn, path in targets:
        if not os.path.isfile(path):
            print(f"[error] missing file: {path}")
            return 1
    ok = True
    for fn, path in targets:
        ok = fn(path) and ok
    if not ok:
        print("PATCH FAILED")
        return 1
    print("PATCH OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
