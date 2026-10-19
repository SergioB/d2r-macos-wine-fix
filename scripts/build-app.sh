#!/bin/bash
# Build a standalone "Diablo II Resurrected.app" (no Porting Kit needed at runtime) from:
#   - the Porting Kit engine WS12Wine11.0_1_DXMT-v0.80 (Wine 11.0, as used by Porting Kit's D2R port)
#   - an existing Porting Kit D2R wrapper (support libraries; optionally its Wine prefix)
#   - official downloads: MoltenVK 1.4.2 (Khronos) and Wine 11.0 stable for macOS (Gcenx, for dxgi.dll)
#   - a wined3d.dll built from Wine 11.0 + patches/0002 + 0003 (see scripts/build-wined3d.sh)
#
# usage: scripts/build-app.sh --wrapper <Porting Kit D2R .app> --wined3d <wined3d.dll>
#                             [--app <dest .app>] [--prefix <prefix dir>] [--move-prefix]
#                             [--engine-archive <WS12Wine11.0_1_DXMT-v0.80.tar.7z>]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Diablo II Resurrected.app"
PREFIX="$HOME/Games/Diablo II Resurrected/prefix"
ENGINE_ARCHIVE="$HOME/Library/Application Support/Wineskin/Engines/WS12Wine11.0_1_DXMT-v0.80.tar.7z"
WRAPPER=""; WINED3D=""; MOVE_PREFIX=0
CACHE="${D2R_CACHE:-$HOME/Library/Caches/d2r-macos-wine-fix}"

MVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar"
MVK_SHA256="f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"
WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz"
WINE_SHA256="b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
ENGINE_SHA256="5d7a09ab65a434607898307d9a382a864823edaf7daf11b8572ff6090c4f1589"
DXGI_SHA256="28bd758d94e44da145477bd070424ec88bf15a1518621fe6d31c15406a622d4b"

die() { echo "error: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --wrapper) WRAPPER="$2"; shift 2 ;;
        --wined3d) WINED3D="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --move-prefix) MOVE_PREFIX=1; shift ;;
        --engine-archive) ENGINE_ARCHIVE="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown argument $1" ;;
    esac
done

[ "$(uname -m)" = arm64 ] || die "this targets Apple Silicon Macs"
[ -n "$WRAPPER" ] && [ -d "$WRAPPER/Contents/Frameworks" ] || die "--wrapper must point to a Porting Kit wrapper .app"
[ -n "$WINED3D" ] && [ -f "$WINED3D" ] || die "--wined3d must point to the patched wined3d.dll"
[ -f "$ENGINE_ARCHIVE" ] || die "engine archive not found: $ENGINE_ARCHIVE (install the D2R port in Porting Kit once)"
SEVENZ="/Applications/Porting Kit.app/Contents/Resources/app.asar.unpacked/node_modules/7zip-bin/mac/arm64/7za"
[ -x "$SEVENZ" ] || SEVENZ="$(command -v 7zz || command -v 7za || true)"
[ -n "$SEVENZ" ] || die "7-Zip not found (needed to unpack the Porting Kit engine)"
if pgrep -f 'wineserver|D2R\.exe|Battle\.net\.exe' >/dev/null; then die "Wine is running; quit Battle.net/D2R first"; fi

[ "$(sha "$ENGINE_ARCHIVE")" = "$ENGINE_SHA256" ] || echo "warning: engine archive checksum differs from the tested one"

mkdir -p "$CACHE"
fetch() { # url sha256 file
    [ -f "$3" ] && [ "$(sha "$3")" = "$2" ] && return 0
    echo "downloading $1"; curl -fL --retry 3 -o "$3.part" "$1"; mv "$3.part" "$3"
    [ "$(sha "$3")" = "$2" ] || die "checksum mismatch for $3"
}
fetch "$MVK_URL" "$MVK_SHA256" "$CACHE/MoltenVK-macos.tar"
fetch "$WINE_URL" "$WINE_SHA256" "$CACHE/wine-stable-11.0_1-osx64.tar.xz"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/Diablo II Resurrected.app"
RES="$STAGE/Contents/Resources"
mkdir -p "$STAGE/Contents/MacOS" "$RES/moltenvk"

echo "unpacking engine"
"$SEVENZ" x -so "$ENGINE_ARCHIVE" 2>/dev/null | tar -xf - -C "$WORK"
mv "$WORK/wswine.bundle" "$RES/wine"
E="$RES/wine/lib/wine"

echo "patching ntdll.so (check_invalid_gsbase)"
python3 "$REPO/scripts/patch-ntdll.py" "$E/x86_64-unix/ntdll.so"
codesign --force -s - "$E/x86_64-unix/ntdll.so" 2>/dev/null

echo "installing stock Wine 11.0 dxgi.dll (DXMT's dxgi breaks vkd3d's D3D12 device creation)"
tar -xJf "$CACHE/wine-stable-11.0_1-osx64.tar.xz" -C "$WORK" "Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-windows/dxgi.dll"
DXGI="$WORK/Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-windows/dxgi.dll"
[ "$(sha "$DXGI")" = "$DXGI_SHA256" ] || die "unexpected dxgi.dll"
cp "$DXGI" "$E/x86_64-windows/dxgi.dll"

echo "installing patched wined3d.dll (vkd3d: pass-through tessellation, null cube SRVs)"
LC_ALL=C grep -aq "Bypassing tessellation" "$WINED3D" || die "$WINED3D is not the patched wined3d.dll"
cp "$WINED3D" "$E/x86_64-windows/wined3d.dll"
printf 'wine portingkit 11.0 (DXMT) + d2r-macos-wine-fix\n' > "$RES/wine/version"

echo "installing MoltenVK 1.4.2 (x86_64 slice)"
tar -xf "$CACHE/MoltenVK-macos.tar" -C "$WORK" MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
lipo "$WORK/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" -thin x86_64 -output "$RES/moltenvk/libMoltenVK.dylib"
codesign --force -s - "$RES/moltenvk/libMoltenVK.dylib" 2>/dev/null

echo "copying support libraries from the wrapper"
rsync -a --exclude moltenvkcx --exclude libMoltenVK.dylib "$WRAPPER/Contents/Frameworks/" "$RES/Frameworks/"

cp "$REPO/launcher/d2r-launcher.sh" "$STAGE/Contents/MacOS/d2r-launcher"
chmod +x "$STAGE/Contents/MacOS/d2r-launcher"
cp "$REPO/launcher/Info.plist" "$STAGE/Contents/Info.plist"
[ -f "$WRAPPER/Contents/Resources/Wineskin.icns" ] && cp "$WRAPPER/Contents/Resources/Wineskin.icns" "$RES/d2r.icns"
printf '%s\n' "$PREFIX" > "$RES/prefix-path"

if [ "$MOVE_PREFIX" = 1 ]; then
    SRC="$WRAPPER/Contents/SharedSupport/prefix"
    [ -d "$SRC/drive_c" ] || die "no prefix in $SRC"
    [ -e "$PREFIX" ] && die "$PREFIX already exists; not overwriting"
    mkdir -p "$(dirname "$PREFIX")"
    echo "moving Wine prefix $SRC -> $PREFIX"
    mv "$SRC" "$PREFIX"
    printf 'This prefix was moved to %s by d2r-macos-wine-fix.\nMove it back here to use this wrapper again.\n' "$PREFIX" \
        > "$WRAPPER/Contents/SharedSupport/PREFIX-MOVED.txt"
fi
[ -d "$PREFIX/drive_c" ] || echo "warning: no Wine prefix at $PREFIX yet (use --move-prefix or set it up)"

if [ -e "$APP" ]; then
    BAK="$APP.previous-$(date +%Y%m%d-%H%M%S)"; echo "existing app moved to $BAK"; mv "$APP" "$BAK"
fi
mkdir -p "$(dirname "$APP")"
mv "$STAGE" "$APP"
echo "done: $APP (prefix: $PREFIX)"
