#!/usr/bin/env bash
# Builds the libmpv Lumtub ships in its Linux AppImage.
#
#   build.sh <x86_64|aarch64> <output folder>
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
# Only playback is built: FFmpeg keeps the decoders Lumtub can meet, every
# demuxer, parser, bitstream filter, protocol and filter, PNG and MJPEG
# encoders for screenshots, and no muxers or devices. Downloads are merged
# by a separate ffmpeg program, not this one.
set -euo pipefail

arch=$1
mkdir -p "$2"
out=$(realpath "$2")
here=$(dirname "$(realpath "$0")")
# shellcheck source=/dev/null
source "$here/../sources.env"
case $arch in
  x86_64) triple=x86_64-linux-gnu ;;
  aarch64) triple=aarch64-linux-gnu ;;
  *) echo "unknown architecture $arch" >&2; exit 2 ;;
esac
[[ $(uname -m) == "$arch" ]] || { echo "build $arch on an $arch machine" >&2; exit 2; }

jobs=$(nproc)
work=${WORK:-$(mktemp -d)}
src=$work/src
prefix=$work/prefix
mkdir -p "$src" "$prefix"
export PKG_CONFIG_PATH=$prefix/lib/pkgconfig:$prefix/lib/$triple/pkgconfig:$prefix/share/pkgconfig
export PATH=$prefix/bin:$PATH
export CFLAGS="-O2 -fPIC -fno-semantic-interposition"
export CXXFLAGS=$CFLAGS
# Static libraries carry their own dependencies in Libs.private.
mkdir -p "$work/bin"
cat > "$work/bin/pkg-config-static" <<'EOF'
#!/bin/sh
exec pkg-config --static "$@"
EOF
chmod +x "$work/bin/pkg-config-static"

fetch() { # name url ref
  local dir=$src/$1
  [[ -d $dir/.git ]] && return
  git -c advice.detachedHead=false clone --quiet --depth 1 --recurse-submodules --shallow-submodules --branch "$3" "$2" "$dir" 2>/dev/null ||
    { git clone --quiet --filter=blob:none "$2" "$dir" && git -C "$dir" -c advice.detachedHead=false checkout --quiet "$3" && git -C "$dir" submodule update --quiet --init --recursive --depth 1; }
  echo "$1 $(git -C "$dir" describe --tags --always 2>/dev/null) $(git -C "$dir" rev-parse HEAD)" >> "$work/versions.txt"
}

meson_static() { # dir [options]
  local dir=$1; shift
  meson setup "$dir/build" "$dir" --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=static -Db_staticpic=true --wrap-mode=nodownload "$@"
  ninja -C "$dir/build" -j"$jobs"
  ninja -C "$dir/build" install
}

: > "$work/versions.txt"
fetch mpv https://github.com/mpv-player/mpv.git "$MPV_REF"
fetch ffmpeg https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_REF"
fetch dav1d https://github.com/videolan/dav1d.git "$DAV1D_REF"
fetch libass https://github.com/libass/libass.git "$LIBASS_REF"
fetch libplacebo https://github.com/haasn/libplacebo.git "$LIBPLACEBO_REF"
fetch mbedtls https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS_REF"
fetch luajit https://github.com/LuaJIT/LuaJIT.git "$LUAJIT_REF"
fetch curl https://github.com/curl/curl.git "$CURL_REF"
fetch wayland https://gitlab.freedesktop.org/wayland/wayland.git "$WAYLAND_REF"
fetch wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$WAYLAND_PROTOCOLS_REF"

# Wayland: Ubuntu 22.04 has 1.20, mpv needs 1.21 or newer. Shared, so it is
# the one copy every Wayland user in the process shares; bundled below.
meson setup "$src/wayland/build" "$src/wayland" --prefix="$prefix" --libdir=lib --buildtype=release \
  -Ddocumentation=false -Dtests=false -Ddtd_validation=false
ninja -C "$src/wayland/build" -j"$jobs" install
meson setup "$src/wayland-protocols/build" "$src/wayland-protocols" --prefix="$prefix" --libdir=lib -Dtests=false
ninja -C "$src/wayland-protocols/build" install

meson_static "$src/dav1d" -Denable_tools=false -Denable_tests=false

cmake -S "$src/mbedtls" -B "$src/mbedtls/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON
ninja -C "$src/mbedtls/build" -j"$jobs" install

# libcurl: mpv streams http(s) through it (curl-max-request-size and the
# rest). mbedTLS, with the system's certificate folder, which every common
# distribution has at /etc/ssl/certs.
cmake -S "$src/curl" -B "$src/curl/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
  -DCURL_USE_MBEDTLS=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF \
  -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_DISABLE_LDAP=ON -DCURL_USE_GSSAPI=OFF \
  -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=/etc/ssl/certs -DCURL_CA_FALLBACK=OFF -DHTTP_ONLY=ON
ninja -C "$src/curl/build" -j"$jobs" install

make -C "$src/luajit" -j"$jobs" amalg BUILDMODE=static PREFIX="$prefix" XCFLAGS="-fPIC" CFLAGS="-O2 -fPIC"
make -C "$src/luajit" install BUILDMODE=static PREFIX="$prefix"
rm -f "$prefix"/lib/libluajit-5.1.so*

meson_static "$src/libass" -Dfontconfig=enabled -Dlibunibreak=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

meson_static "$src/libplacebo" -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dopengl=enabled \
  -Dd3d11=disabled -Dlcms=enabled -Ddovi=disabled -Dlibdovi=disabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false -Dxxhash=disabled

decoders=(
  h264 hevc vp8 vp9 av1 libdav1d mpeg4 mpeg2video mpeg1video vc1 theora mjpeg png webp gif bmp
  aac aac_latm aac_fixed opus libopus mp3 mp3float mp2 vorbis flac alac ac3 eac3 dca truehd
  pcm_s16le pcm_s16be pcm_s24le pcm_s32le pcm_f32le pcm_u8 pcm_alaw pcm_mulaw
  avif
  webvtt subrip srt ass ssa mov_text text dvbsub dvdsub pgssub
)
mapfile -t known < <("$src/ffmpeg/configure" --list-decoders | tr -s ' \t' '\n' | grep .)
enable=()
for d in "${decoders[@]}"; do
  printf '%s\n' "${known[@]}" | grep -qx "$d" && enable+=("--enable-decoder=$d") || echo "FFmpeg has no decoder $d; skipped"
done
mkdir -p "$src/ffmpeg/build"
(cd "$src/ffmpeg/build" && ../configure --prefix="$prefix" --pkg-config="$work/bin/pkg-config-static" \
  --enable-static --disable-shared --enable-pic --disable-programs --disable-doc --disable-debug \
  --disable-autodetect --disable-encoders --disable-muxers --disable-devices --disable-decoders \
  --disable-hwaccels --disable-postproc \
  "${enable[@]}" --enable-encoder=png --enable-encoder=mjpeg \
  --enable-libdav1d --enable-mbedtls --enable-version3 --enable-zlib --enable-iconv \
  --enable-vaapi --enable-vdpau --enable-libdrm \
  --enable-hwaccel=h264_vaapi --enable-hwaccel=hevc_vaapi --enable-hwaccel=vp8_vaapi --enable-hwaccel=vp9_vaapi \
  --enable-hwaccel=av1_vaapi --enable-hwaccel=mpeg2_vaapi --enable-hwaccel=vc1_vaapi \
  --enable-hwaccel=h264_vdpau --enable-hwaccel=hevc_vdpau --enable-hwaccel=vp9_vdpau --enable-hwaccel=av1_vdpau \
  --enable-hwaccel=mpeg2_vdpau --enable-hwaccel=vc1_vdpau \
  --extra-cflags="$CFLAGS -I$prefix/include" --extra-ldflags="-L$prefix/lib")
make -C "$src/ffmpeg/build" -j"$jobs"
make -C "$src/ffmpeg/build" install

# libmpv with everything above inside it. --exclude-libs keeps the static
# libraries' symbols out of libmpv's exports.
LDFLAGS="-Wl,--exclude-libs,ALL -L$prefix/lib" PKG_CONFIG="$work/bin/pkg-config-static" \
  meson setup "$src/mpv/build" "$src/mpv" --prefix="$prefix" --libdir=lib --buildtype=release \
  -Dlibmpv=true -Dcplayer=false -Dtests=false -Dfuzzers=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dlua=luajit -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled \
  -Duchardet=disabled -Drubberband=disabled -Dzimg=disabled -Dvapoursynth=disabled -Dlcms2=enabled -Djpeg=enabled \
  -Dlibcurl=enabled -Dzlib=enabled -Diconv=enabled \
  -Dgl=enabled -Degl=enabled -Dx11=enabled -Dwayland=enabled -Ddrm=enabled -Dgbm=enabled \
  -Dvulkan=disabled -Dvaapi=enabled -Dvdpau=enabled \
  -Dalsa=enabled -Dpulse=enabled -Dpipewire=enabled -Djack=enabled -Dsndio=enabled -Dopenal=disabled -Dsdl2-audio=disabled -Dsdl2-video=disabled
ninja -C "$src/mpv/build" -j"$jobs" install

# The package, laid out like the one Lumtub's Linux build used before.
mpv_version=$(sed -n 's/^Version: *//p' "$prefix/lib/pkgconfig/mpv.pc")
pkg=$out/pkg
rm -rf "$pkg"
mkdir -p "$pkg/lib/pkgconfig" "$pkg/include" "$pkg/licenses"
cp -a "$prefix"/lib/libmpv.so* "$pkg/lib/"
strip --strip-unneeded "$pkg"/lib/libmpv.so.*.*.*
cp -r "$prefix/include/mpv" "$pkg/include/"
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

lic() { local name=$1; shift; for f in "$@"; do [[ -f $f ]] && { cp "$f" "$pkg/licenses/$name-$(basename "$f")"; return; }; done; echo "no license file for $name" >&2; exit 1; }
lic mpv "$src/mpv/LICENSE.GPL"
lic ffmpeg "$src/ffmpeg/COPYING.LGPLv3"
lic dav1d "$src/dav1d/COPYING"
lic libass "$src/libass/COPYING"
lic libplacebo "$src/libplacebo/LICENSE"
lic mbedtls "$src/mbedtls/LICENSE"
lic luajit "$src/luajit/COPYRIGHT"
lic wayland "$src/wayland/COPYING"
lic curl "$src/curl/COPYING"
cp "$work/versions.txt" "$pkg/licenses/sources.txt"

mpv_commit=$(git -C "$src/mpv" rev-parse HEAD)
glibc=$(find "$pkg/lib" -type f -name '*.so*' -exec objdump -T {} \; 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
cat > "$pkg/manifest.txt" <<EOF
name=libmpv
os=linux
arch=$arch
mpv=$(git -C "$src/mpv" describe --tags --always)
mpv_commit=$mpv_commit
libmpv_version=$mpv_version
ffmpeg=$(git -C "$src/ffmpeg" describe --tags --always)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
newest_glibc_symbol=$glibc
license=GPL-2.0-or-later
linux_bundled_deps=yes
EOF
cat "$pkg/manifest.txt"
echo "$mpv_commit" > "$out/mpv-commit.txt"
