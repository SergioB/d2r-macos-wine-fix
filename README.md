# d2r-macos-wine-fix

Fixes that make **Diablo II: Resurrected** (current build, 3.3.93847) run on **Apple Silicon Macs**
through Wine, with full HD graphics, plus a standalone launcher app that doesn't depend on Porting Kit.

Tested on: MacBook Air M3 · macOS 26.6.2 · Wine 11.0 (Porting Kit engine `WS12Wine11.0_1_DXMT-v0.80`) ·
MoltenVK 1.4.2 · Battle.net 2.53.5 · D2R 3.3.93847 · HD and Legacy graphics.

No Blizzard files are modified.

## What was broken

Starting from Porting Kit's "Diablo 2 - Resurrected" port (id 1769), there were four independent bugs,
found and fixed one after another:

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `Failed to initialize graphics device` (`D3D12CreateDevice Failed`, `0x80004002`) | The engine's DXMT `dxgi.dll` doesn't provide the adapter interface Wine's D3D12 (vkd3d) needs (`d3d12_get_adapter Invalid adapter`) | Use Wine 11.0's stock `dxgi.dll` |
| 2 | Black window forever at startup (main thread spinning in signal handling) | **Wine bug** in `check_invalid_gsbase()` (macOS only): an access violation on an instruction that straddles into an inaccessible page is mistaken for a `%gs` fault and silently retried forever. D2R's protection decrypts code pages on demand through such faults (~40,000 retries/s) | `patches/0001`, or `scripts/patch-ntdll.py` for the prebuilt engine |
| 3 | Black ground in the game world | D2R draws terrain through a *pass-through* hull/domain shader pair (tessellation factor 1). MoltenVK's tessellation emulation draws nothing for it | `patches/0002`: vkd3d draws those 3-point patches as plain triangles |
| 4 | Random startup hang (~50%), worse in windowed mode | vkd3d's `device_worker` thread ends up still owning MoltenVK's residency-set lock (`@synchronized(_residencySet)` in `makeResident()`); the game's main thread then blocks forever in `vkUpdateDescriptorSets` | `VKD3D_CONFIG=virtual_heaps` (no `device_worker` thread) |

`patches/0003` additionally implements null cube-map SRVs in vkd3d (harmless correctness fix found
along the way). The MoltenVK settings from
[JakeDahl/D2R-MacOS-Setup](https://github.com/JakeDahl/D2R-MacOS-Setup) (semaphore style 2, argument
buffers, concurrent compilation) are used too; MoltenVK itself is the unmodified 1.4.2 release.
Disabling MoltenVK residency sets also avoids bug 4, but makes the frame rate degrade over time
(50 → 23 FPS in 100 s), so virtual heaps is the better workaround.

The full investigation is in [docs/investigation.md](docs/investigation.md); upstream report drafts
are in [docs/upstream](docs/upstream).

## Requirements

- Apple Silicon Mac, macOS 15 or later (tested on 26.6)
- [Porting Kit](https://www.portingkit.com) with the **Diablo 2 - Resurrected** port installed once, and
  Battle.net logged in + D2R downloaded inside it. Its engine archive and support libraries are reused.
- `python3`, `curl`, `codesign`, `lipo` (Xcode command line tools)
- The patched `wined3d.dll`: download it from this repository's Releases, or build it with
  `scripts/build-wined3d.sh` (~2 min on an M3; needs `brew install bison mingw-w64 pkgconf freetype gnutls`).
  The build is reproducible: code and data sections match the released binary byte for byte (only the
  PE timestamp/checksum differ).

## Install

```sh
git clone https://github.com/<you>/d2r-macos-wine-fix && cd d2r-macos-wine-fix
# quit Battle.net / D2R first
scripts/build-app.sh \
    --wrapper "/path/to/Diablo 2 Resurrected.app" \
    --wined3d /path/to/wined3d.dll \
    --prefix "$HOME/Games/Diablo II Resurrected/prefix" --move-prefix
```

This creates `~/Applications/Diablo II Resurrected.app`, a self-contained launcher with its own fixed
Wine engine, MoltenVK and libraries. With `--move-prefix` the wrapper's Wine prefix (Battle.net and the
~30 GB game) is **moved** (instant, same disk) out of the Porting Kit wrapper, so Porting Kit updates
can't touch it. To go back, move the prefix folder back to `<wrapper>/Contents/SharedSupport/prefix`.

## Usage

- Double-click **Diablo II Resurrected.app**: starts Battle.net, then press Play.
- Or from a terminal: `".../Diablo II Resurrected.app/Contents/MacOS/d2r-launcher" direct` starts D2R
  directly with the cached Battle.net login. Other modes: `winecfg`, `kill`.
- Log: `~/Library/Logs/d2r-launcher.log`. Set `WINEDEBUG`, `MVK_CONFIG_LOG_LEVEL=2` etc. for debugging.

## Known issues

- Don't Cmd-Tab out right after launch while D2R is loading.
- vkd3d's `virtual_heaps` mode costs a little CPU compared with Vulkan heaps.

## License

The patches in `patches/` modify Wine and vkd3d and are under the **LGPL 2.1 or later**, like those
projects; the released `wined3d.dll` is built from Wine 11.0 sources + these patches with
`scripts/build-wined3d.sh`. Everything else (scripts, launcher, docs) is MIT licensed, see `LICENSE`.
Diablo II: Resurrected and Battle.net are trademarks of Blizzard Entertainment; this project is not
affiliated with Blizzard, CodeWeavers, Porting Kit or the Khronos Group.
