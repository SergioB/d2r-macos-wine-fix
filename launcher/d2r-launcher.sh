#!/bin/bash
# Diablo II: Resurrected launcher (d2r-macos-wine-fix)
#
# Runs Battle.net (default) or D2R directly from a Wine prefix, using the patched Wine engine and
# MoltenVK bundled inside this app. Usage (also works when the .app is double-clicked):
#   d2r-launcher.sh [battlenet|direct|winecfg|kill]
# Overrides: D2R_PREFIX=<prefix dir>, WINEDEBUG=..., VKD3D_CONFIG=..., D2R_LOG=<file>

APP="$(cd "$(dirname "$0")/../.." && pwd)"
RES="$APP/Contents/Resources"
WINE="$RES/wine"

if [ -z "$D2R_PREFIX" ] && [ -f "$RES/prefix-path" ]; then
    D2R_PREFIX="$(cat "$RES/prefix-path")"
fi
export WINEPREFIX="${D2R_PREFIX:?no prefix configured (set D2R_PREFIX or Contents/Resources/prefix-path)}"

# macOS strips DYLD_* variables whenever a SIP-protected binary (/bin/bash, /usr/bin/env, nohup, ...)
# is executed, so they must be set here, right before exec'ing the (unprotected) wine binary.
export PATH="$WINE/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DYLD_FALLBACK_LIBRARY_PATH="$RES/moltenvk:$WINE/lib:$RES/Frameworks:/usr/lib:/usr/libexec:/usr/lib/system"
export WINEESYNC=1 WINEMSYNC=1
export WINEDEBUG="${WINEDEBUG:--all}"

# MoltenVK settings (MoltenVK >= 1.4): real Metal events for DX12 fences, Metal argument buffers,
# concurrent pipeline compilation, errors-only logging.
export MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE=2
export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1
export MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1
export MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=1024
export MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}"

# vkd3d "virtual heaps": avoids vkd3d's device_worker thread, which can leave MoltenVK's
# residency-set lock held and deadlock the game at startup.
export VKD3D_CONFIG="${VKD3D_CONFIG:-virtual_heaps}"

LOG="${D2R_LOG:-$HOME/Library/Logs/d2r-launcher.log}"
mode="$1"
case "$mode" in -psn_*|"") mode=battlenet ;; esac

{ echo "===== $(date) mode=$mode prefix=$WINEPREFIX"; } >>"$LOG"

case "$mode" in
    battlenet)
        cd "$WINEPREFIX/drive_c/Program Files (x86)/Battle.net" || exit 1
        "$WINE/bin/wine64" "C:\\Program Files (x86)\\Battle.net\\Battle.net Launcher.exe" >>"$LOG" 2>&1 ;;
    direct)
        cd "$WINEPREFIX/drive_c/Program Files (x86)/Diablo II Resurrected" || exit 1
        "$WINE/bin/wine64" "C:\\Program Files (x86)\\Diablo II Resurrected\\D2R.exe" -uid osi >>"$LOG" 2>&1 ;;
    winecfg)
        "$WINE/bin/wine64" winecfg >>"$LOG" 2>&1 ;;
    kill)
        exec "$WINE/bin/wineserver" -k ;;
    *)
        echo "usage: $0 [battlenet|direct|winecfg|kill]" >&2; exit 2 ;;
esac

# Keep the app "running" until the whole Wine session (Battle.net, Agent, D2R) has exited.
exec "$WINE/bin/wineserver" -w
