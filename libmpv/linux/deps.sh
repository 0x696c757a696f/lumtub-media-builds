#!/usr/bin/env bash
# Builds everything libmpv links in statically (and Wayland), into
# $WORK/prefix. Only pinned releases from sources.env, so CI caches the
# prefix and rebuilds it only when this file, common.sh or sources.env
# changes; with a complete prefix this does nothing.
#
#   deps.sh <x86_64|aarch64> [v3]
arch=$1
level=${2:-}
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"
if [[ -f $prefix/.complete ]]; then
  echo "Dependencies already built in $prefix"
  exit 0
fi
rm -rf "$prefix" "$src"
mkdir -p "$prefix" "$src"

: > "$work/versions.txt"
fetch ffmpeg https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_REF"
fetch dav1d https://github.com/videolan/dav1d.git "$DAV1D_REF"
fetch libass https://github.com/libass/libass.git "$LIBASS_REF"
fetch libplacebo https://github.com/haasn/libplacebo.git "$LIBPLACEBO_REF"
fetch mbedtls https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS_REF"
fetch luajit https://github.com/LuaJIT/LuaJIT.git "$LUAJIT_REF"
fetch curl https://github.com/curl/curl.git "$CURL_REF"
fetch nv-codec-headers https://github.com/FFmpeg/nv-codec-headers.git "$NVCODEC_REF"
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

make -C "$src/luajit" -j"$jobs" amalg BUILDMODE=static PREFIX="$prefix" XCFLAGS="-fPIC" CFLAGS="$CFLAGS"
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
  webvtt subrip srt ass ssa movtext text dvbsub dvdsub pgssub
)
mapfile -t known < <("$src/ffmpeg/configure" --list-decoders | tr -s ' \t' '\n' | grep .)
enable=()
for d in "${decoders[@]}"; do
  printf '%s\n' "${known[@]}" | grep -qx "$d" && enable+=("--enable-decoder=$d") || echo "FFmpeg has no decoder $d; skipped"
done
make -C "$src/nv-codec-headers" PREFIX="$prefix" install > /dev/null

mkdir -p "$src/ffmpeg/build"
(cd "$src/ffmpeg/build" && ../configure --prefix="$prefix" --pkg-config="$work/bin/pkg-config-static" \
  --enable-static --disable-shared --enable-pic --disable-programs --disable-doc --disable-debug \
  --disable-autodetect --disable-encoders --disable-muxers --disable-devices --disable-decoders \
  --disable-hwaccels \
  "${enable[@]}" --enable-encoder=png --enable-encoder=mjpeg \
  --enable-libdav1d --enable-mbedtls --enable-version3 --enable-zlib --enable-iconv \
  --enable-vaapi --enable-vdpau --enable-libdrm \
  --enable-hwaccel=h264_vaapi --enable-hwaccel=hevc_vaapi --enable-hwaccel=vp8_vaapi --enable-hwaccel=vp9_vaapi \
  --enable-hwaccel=av1_vaapi --enable-hwaccel=mpeg2_vaapi --enable-hwaccel=vc1_vaapi \
  --enable-hwaccel=h264_vdpau --enable-hwaccel=hevc_vdpau --enable-hwaccel=vp9_vdpau --enable-hwaccel=av1_vdpau \
  --enable-hwaccel=mpeg2_vdpau --enable-hwaccel=vc1_vdpau \
  --enable-ffnvcodec --enable-nvdec \
  --enable-hwaccel=h264_nvdec --enable-hwaccel=hevc_nvdec --enable-hwaccel=vp8_nvdec --enable-hwaccel=vp9_nvdec \
  --enable-hwaccel=av1_nvdec --enable-hwaccel=mpeg2_nvdec --enable-hwaccel=vc1_nvdec \
  --extra-cflags="$CFLAGS -I$prefix/include" --extra-ldflags="-L$prefix/lib")
make -C "$src/ffmpeg/build" -j"$jobs"
make -C "$src/ffmpeg/build" install

# Their licenses and versions go into the prefix, which is what gets cached.
mkdir -p "$prefix/licenses"
lic() { local name=$1; shift; for f in "$@"; do [[ -f $f ]] && { cp "$f" "$prefix/licenses/$name-$(basename "$f")"; return; }; done; echo "no license file for $name" >&2; exit 1; }
lic ffmpeg "$src/ffmpeg/COPYING.LGPLv3"
lic nv-codec-headers "$src/nv-codec-headers/include/ffnvcodec/dynlink_loader.h"
lic dav1d "$src/dav1d/COPYING"
lic libass "$src/libass/COPYING"
lic libplacebo "$src/libplacebo/LICENSE"
lic mbedtls "$src/mbedtls/LICENSE"
lic luajit "$src/luajit/COPYRIGHT"
lic wayland "$src/wayland/COPYING"
lic curl "$src/curl/COPYING"
echo "ffmpeg_describe=$(git -C "$src/ffmpeg" describe --tags --always)" > "$prefix/deps.txt"
cp "$work/versions.txt" "$prefix/versions.txt"
touch "$prefix/.complete"
