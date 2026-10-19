# Investigation notes

Machine: MacBook Air M3 (Mac15,13), 24 GB, macOS 26.6.2 (25G83). Game: D2R build 93847, Battle.net 2.53.5.
Starting point: Porting Kit port 1769 "Diablo 2 - Resurrected", engine `WS12Wine11.0_1_DXMT-v0.80`.

## 1. `Failed to initialize graphics device`

D2R's `blz-log.txt`:

```
prism: Error Invalid (0x80004002): pm_dx12::Instance::CreateDevice: D3D12CreateDevice Failed
prism: Error Invalid (0x80004002): pm_api::PlatformInstance::CreateDevice: Unsupported API Backend
Fatal: failed to create device.
```

D2R only has a D3D12 renderer. In the engine, `d3d11.dll`/`dxgi.dll` are DXMT and `d3d12.dll` is Wine's
vkd3d (via MoltenVK). With `WINEDEBUG=warn+d3d12`:

```
warn:d3d12:d3d12_get_adapter Invalid adapter 0000000005C7DFF0, hr 0x80004002.
```

Wine's d3d12 queries the DXGI adapter for an interface that only Wine's own (wined3d-based) dxgi
implements; DXMT's dxgi does not. Replacing `dxgi.dll` with Wine 11.0's stock build fixes device creation.

Dead ends: Kegworks/Sikarugir Wine 10 + D3DMetal 2.1 and CrossOver 23.7 crash in `D2R_loader.dll`
(the game's protection) before reaching graphics; Gcenx's CrossOver 26.3 builds deadlock in the
protection's thread setup; D3DMetal DLLs need `__wine_unix_call` (removed in Wine 11) and CrossOver's
`macdrv_functions` (absent from upstream winemac.so).

## 2. Endless black window at startup

After 1. the game crawled: shaders compiled in bursts (154 after ~6 minutes) and then nothing.
`sample` showed the main thread almost entirely in `_sigtramp` / Rosetta runtime routines, with no
exceptions or `SIGSYS` visible in `+seh` traces. Counting signals inside ntdll (instrumented build):

```
SIGSTATS segv-handled #4000 tid 0024 rip 0x1400a6fff addr 0x1400a7000
...  ~40,000 per second, same rip for thousands of iterations
```

`virtual_handle_fault()` correctly returned `STATUS_ACCESS_VIOLATION` (execute fault on a `PROT_NONE`
page of D2R.exe's own image), but `segv_handler()` still swallowed it because
`check_invalid_gsbase()` returned TRUE. On macOS that function can't read the old gs base, so it decodes
the faulting instruction: with RIP on the last byte of a readable page only one byte (a REX prefix) can be
read, the prefix loop runs out of input and falls through to "fixing up" without having seen `0x65`.
The game's protection never receives the access violation it uses to decrypt the next code page.
Returning FALSE unless a `%gs` prefix was actually seen (patch 0001) brings startup from "never" to ~2 s
(2174 shaders in 30 s).

## 3. Black ground

Colour-coding experiments (replacing pixel shader outputs with constant colours per shader group)
showed that no pixel shader ever wrote the ground pixels - the ground wasn't drawn at all; the black was
the scene buffer's clear colour. The game's only hull/domain shader pair is a pass-through:

```glsl
// hull: copy control points, all tessellation factors 1.0
// domain: gl_Position = interpolate(v0); o1..o5 = interpolate(v1..v5) by gl_TessCoord
```

and its pixel shader is the terrain lighting shader. Under MoltenVK's compute-based tessellation
emulation these draws produce nothing. Since tessellation factor 1 with barycentric interpolation is the
identity, vkd3d can drop the HS/DS stages and draw `D3D_PRIMITIVE_TOPOLOGY_3_CONTROL_POINT_PATCHLIST` as
a triangle list; the VS outputs already match the PS inputs by location (patch 0002). Ground renders.

Ruled out on the way: null cube-map SRVs (`vkd3d_create_null_srv Unhandled view dimension 0x9`,
fixed anyway in patch 0003), vkd3d descriptor model (`virtual_heaps`), 3D light-volume data, ambient
occlusion, render-target clears, integer render-target blending (MoltenVK already disables it).

## 4. Random startup hang

About half of the launches hang with the main thread in

```
vkUpdateDescriptorSets -> writeDescriptorSetCPUBufferDispatch -> MVKBuffer::getMTLBuffer
  -> MVKDevice::makeResident -> @synchronized(_residencySet) -> objc_sync_enter -> __ulock_wait2
```

Attaching lldb to a hung process, the lock word was `0x14412`, i.e. owner thread port `0x14413`
(no-waiters bit cleared) - vkd3d's `device_worker` thread, sitting idle in `NtWaitForAlertByThreadId`
while still owning the lock. `device_worker` performs asynchronous descriptor writes (Vulkan-heaps mode),
so it calls the same MoltenVK path; it must have left the `@synchronized` region abnormally. The thread
terminations seen in the wineserver protocol trace are all normal self-exits, and no unix-side faults in
MoltenVK were traced, so the exact exit path is still open (see docs/upstream/moltenvk-residency-lock.md).

Workarounds: patching MoltenVK not to create the residency set avoids the lock but makes MoltenVK
declare every resource per encoder; the frame rate then degrades steadily (50 → 23 FPS over 100 s on the
character-select screen). `VKD3D_CONFIG=virtual_heaps` removes the `device_worker` thread instead:
4/4 launches clean, steady 43-54 FPS (frame cap 54).
