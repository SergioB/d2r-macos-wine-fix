# Draft: MoltenVK issue

**Title:** Deadlock in `MVKDevice::makeResident()`: `@synchronized(_residencySet)` left held by another thread

## Environment

MoltenVK 1.4.2 (x86_64, Rosetta 2) · macOS 26.6.2 · Apple M3 · Wine 11.0 + vkd3d 1.18 (Vulkan-heaps
descriptor mode) · Diablo II: Resurrected · `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1` (residency sets
active on macOS 15+).

## Description

About 50% of launches hang during startup. The application's main thread blocks in:

```
__ulock_wait2
_os_unfair_lock_lock_slow
objc_sync_enter
MVKBuffer::getMTLBuffer()            (inlined MVKDevice::makeResident -> @synchronized(_residencySet))
writeDescriptorSetCPUBufferDispatch
writeDescriptorSetBinding
mvkUpdateDescriptorSets
vkUpdateDescriptorSets
```

Inspecting the hung process with lldb: the lock word is `0x14412`, i.e. owned by thread port `0x14413`,
which is vkd3d's `device_worker` thread (it performs asynchronous `vkUpdateDescriptorSets` calls). That
thread is idle in an unrelated wait outside MoltenVK, yet still owns the lock, so it seems to have left
the `@synchronized` region without releasing it. No other thread is inside MoltenVK.

Under Wine, unix-side code can be left abnormally (e.g. a fault during a call is turned into an error
return to the Windows side), which would skip `objc_sync_exit`. We haven't captured that event yet;
filing this mainly because `makeResident()` holding an Objective-C `@synchronized` lock around
`[_residencySet addAllocation:]` + `[_residencySet commit]` on arbitrary application threads makes such
lock leaks fatal. Possible mitigations: commit the residency set from a single place (e.g. at queue
submission) instead of on every `makeResident()`, and/or use a plain mutex scope.

## Workarounds

- vkd3d `VKD3D_CONFIG=virtual_heaps` (no `device_worker` thread): no hangs in our tests.
- Not creating the residency set at all also avoids it, but then performance degrades over time
  (50 -> 23 FPS within 100 s), presumably from per-encoder `useResource:` of all argument-buffer resources.
