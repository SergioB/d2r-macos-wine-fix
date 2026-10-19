#!/bin/bash
# Build the patched 64-bit wined3d.dll (which contains vkd3d / D3D12) from Wine 11.0 sources.
# Only wined3d.dll is used from this build; the rest of the runtime is Porting Kit's Wine 11.0 engine.
#
# Requirements (Apple Silicon): Xcode command line tools, Homebrew, and
#   brew install bison mingw-w64 pkgconf freetype gnutls
# usage: scripts/build-wined3d.sh <work dir> [x86_64 lib dir with libfreetype.6.dylib/libgnutls.30.dylib]
# The lib dir defaults to a Porting Kit D2R wrapper's Contents/Frameworks (x86_64 builds of those libs).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:?usage: $0 <work dir> [x86_64 lib dir]}"
LIBS="${2:-}"
WINE_URL="https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz"
WINE_SHA256="c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701"

[ -n "$LIBS" ] || { echo "pass the x86_64 lib dir (e.g. '<Porting Kit D2R wrapper>/Contents/Frameworks')"; exit 1; }
mkdir -p "$WORK"; cd "$WORK"
# paths with spaces break Wine's configure: link the lib dir under a space-free name
ln -sfn "$LIBS" "$WORK/x86_64-libs"; LIBS="$WORK/x86_64-libs"

[ -f wine-11.0.tar.xz ] || curl -fL -o wine-11.0.tar.xz "$WINE_URL"
[ "$(shasum -a 256 wine-11.0.tar.xz | awk '{print $1}')" = "$WINE_SHA256" ] || { echo "bad wine-11.0.tar.xz"; exit 1; }
rm -rf wine-11.0 build && tar -xJf wine-11.0.tar.xz
(cd wine-11.0 && for p in "$REPO"/patches/0002-*.patch "$REPO"/patches/0003-*.patch; do patch -p1 < "$p"; done)
mkdir build

BREW="$(brew --prefix)"
cat > build/env.sh <<EOF
export PATH="$BREW/opt/bison/bin:$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH=   # never pick up arm64 Homebrew libraries
EOF

# The unix side must be x86_64 (Wine runs under Rosetta). Homebrew's freetype/gnutls are arm64, so
# only their headers are used; the x86_64 libraries come from $LIBS.
arch -x86_64 /bin/zsh -c "source build/env.sh; cd build && ../wine-11.0/configure \
    --host=x86_64-apple-darwin --enable-archs=i386,x86_64 --disable-tests \
    --without-x --without-gstreamer --without-sdl --without-cups --without-sane --without-krb5 \
    --without-gphoto --without-netapi --with-freetype --with-gnutls \
    CC='clang -arch x86_64' CXX='clang++ -arch x86_64' OBJC='clang -arch x86_64' \
    FREETYPE_CFLAGS='-I$BREW/include/freetype2' FREETYPE_LIBS='-L$LIBS -lfreetype' \
    GNUTLS_CFLAGS='-I$BREW/opt/gnutls/include' GNUTLS_LIBS='-L$LIBS -lgnutls' \
    LDFLAGS='-L$LIBS' CFLAGS='-O2' CROSSCFLAGS='-O2'"

# Fix-ups for building on a newer SDK than the running macOS / bare install names:
#  - pipe2() is declared by the macOS 27 SDK but missing on macOS 26 (weak symbol -> NULL call)
#  - configure records garbled sonames for libraries with bare install names
python3 - build/include/config.h <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("#define HAVE_PIPE2 1", "/* #undef HAVE_PIPE2 */")
s = re.sub(r'#define SONAME_LIBFREETYPE ".*"', '#define SONAME_LIBFREETYPE "libfreetype.6.dylib"', s)
s = re.sub(r'#define SONAME_LIBGNUTLS ".*"', '#define SONAME_LIBGNUTLS "libgnutls.30.dylib"', s)
open(p, "w").write(s)
EOF
# tools/sfnt2fon loads libfreetype by its bare install name from the current directory at build time
ln -sfn "$LIBS/libfreetype.6.dylib" build/libfreetype.dylib

arch -x86_64 /bin/zsh -c "source build/env.sh; cd build && make -j$(sysctl -n hw.ncpu) dlls/wined3d/all"
OUT="$WORK/wined3d.dll"
cp build/dlls/wined3d/x86_64-windows/wined3d.dll "$OUT"
x86_64-w64-mingw32-strip --strip-debug "$OUT"
LC_ALL=C grep -aq "Bypassing tessellation" "$OUT" && echo "built $OUT ($(shasum -a 256 "$OUT" | awk '{print $1}'))"
