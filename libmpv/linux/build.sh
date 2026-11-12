#!/usr/bin/env bash
# Builds the libmpv Lumtub ships in its Linux AppImage.
#
#   build.sh <x86_64|aarch64> <output folder> [v3]
#
# Runs inside ubuntu:22.04 (glibc 2.35, the oldest glibc the AppImage
# supports) on a runner of the same CPU architecture. Source versions come
# from the environment (see sources.env); MPV_REF picks the mpv commit.
#
# FFmpeg, dav1d, libass, libplacebo, mbedTLS and LuaJIT are linked into
# libmpv.so statically and their symbols hidden, so nothing else in the
# process sees them. System libraries (X11, Wayland, VA-API, audio servers,
# fonts) stay shared and are copied into lib/ next to libmpv, as the
# AppImage packaging expects.
#
# The static dependencies come from deps.sh (cached in CI); this script
# builds them first if they are missing, then mpv itself.
#
# Only playback is built: FFmpeg keeps the decoders Lumtub can meet, every
# demuxer, parser, bitstream filter, protocol and filter, PNG and MJPEG
# encoders for screenshots, and no muxers or devices. Downloads are merged
# by a separate ffmpeg program, not this one.
set -euo pipefail

arch=$1
mkdir -p "$2"
out=$(realpath "$2")
level=${3:-}
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"
WORK=$work "$here/deps.sh" "$arch" $level
# mpv installs beside the dependencies, not into their (cached) prefix.
mpvdir=$work/mpv
rm -rf "$mpvdir"

: > "$work/versions.txt"
fetch mpv https://github.com/mpv-player/mpv.git "$MPV_REF"

# libmpv with everything above inside it. --exclude-libs keeps the static
# libraries' symbols out of libmpv's exports.
LDFLAGS="-Wl,--exclude-libs,ALL -L$prefix/lib" PKG_CONFIG="$work/bin/pkg-config-static" \
  meson setup "$src/mpv/build" "$src/mpv" --prefix="$mpvdir" --libdir=lib --buildtype=release \
  -Dlibmpv=true -Dcplayer=false -Dtests=false -Dfuzzers=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dlua=luajit -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled \
  -Duchardet=disabled -Drubberband=disabled -Dzimg=disabled -Dvapoursynth=disabled -Dlcms2=enabled -Djpeg=enabled \
  -Dlibcurl=enabled -Dzlib=enabled -Diconv=enabled \
  -Dgl=enabled -Degl=enabled -Dx11=enabled -Dwayland=enabled -Ddrm=enabled -Dgbm=enabled \
  -Dvulkan=disabled -Dvaapi=enabled -Dvdpau=enabled -Dcuda-hwaccel=enabled -Dcuda-interop=enabled \
  -Dalsa=enabled -Dpulse=enabled -Dpipewire=enabled -Djack=enabled -Dsndio=enabled -Dopenal=disabled -Dsdl2-audio=disabled -Dsdl2-video=disabled
ninja -C "$src/mpv/build" -j"$jobs" install

# The package, laid out like the one Lumtub's Linux build used before.
mpv_version=$(sed -n 's/^Version: *//p' "$mpvdir/lib/pkgconfig/mpv.pc")
pkg=$out/pkg
rm -rf "$pkg"
mkdir -p "$pkg/lib/pkgconfig" "$pkg/include" "$pkg/licenses"
cp -a "$mpvdir"/lib/libmpv.so* "$pkg/lib/"
strip --strip-unneeded "$pkg"/lib/libmpv.so.*.*.*
cp -r "$mpvdir/include/mpv" "$pkg/include/"
cat > "$pkg/lib/pkgconfig/mpv.pc" <<EOF
prefix=\${pcfiledir}/../..
includedir=\${prefix}/include
libdir=\${prefix}/lib

Name: mpv
Description: mpv media player client library
Version: $mpv_version
Libs: -L\${libdir} -lmpv
Cflags: -I\${includedir}
EOF

# Shared libraries libmpv needs, except glibc's own, which every system has.
skip='^(libc|libm|libdl|libpthread|librt|libresolv|libutil|ld-linux.*)\.so'
LD_LIBRARY_PATH=$prefix/lib ldd "$pkg/lib/libmpv.so" | awk '/=> \//{print $1, $3}' | while read -r name path; do
  [[ $name =~ $skip ]] && continue
  cp -L "$path" "$pkg/lib/$name"
  echo "$name" >> "$pkg/lib/bundled-libraries.txt"
done
if LD_LIBRARY_PATH=$pkg/lib ldd "$pkg/lib/libmpv.so" | grep 'not found'; then
  echo "libmpv has unresolved libraries" >&2
  exit 1
fi

cp "$prefix"/licenses/* "$pkg/licenses/"
cp "$src/mpv/LICENSE.GPL" "$pkg/licenses/mpv-LICENSE.GPL"
cat "$prefix/versions.txt" "$work/versions.txt" > "$pkg/licenses/sources.txt"

mpv_commit=$(git -C "$src/mpv" rev-parse HEAD)
glibc=$(find "$pkg/lib" -type f -name '*.so*' -exec objdump -T {} \; 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
cat > "$pkg/manifest.txt" <<EOF
name=libmpv
os=linux
arch=$arch
cpu_level=${level:-baseline}
mpv=$(git -C "$src/mpv" describe --tags --always)
mpv_commit=$mpv_commit
libmpv_version=$mpv_version
ffmpeg=$(sed -n 's/^ffmpeg_describe=//p' "$prefix/deps.txt")
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
newest_glibc_symbol=$glibc
license=GPL-2.0-or-later
linux_bundled_deps=yes
EOF
cat "$pkg/manifest.txt"
echo "$mpv_commit" > "$out/mpv-commit.txt"
