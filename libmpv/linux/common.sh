# Shared by deps.sh and build.sh: target, folders, compiler flags, fetch().
#
#   arch   x86_64 or aarch64
#   level  empty, or v3 for an x86-64-v3 build (AVX2, FMA, BMI2)
#   WORK   build folder; keep it at the same path between runs so the
#          cached prefix's pkg-config files stay valid
set -euo pipefail

here=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
# shellcheck source=/dev/null
source "$here/../sources.env"
case $arch in
  x86_64) triple=x86_64-linux-gnu ;;
  aarch64) triple=aarch64-linux-gnu ;;
  *) echo "unknown architecture $arch" >&2; exit 2 ;;
esac
[[ $(uname -m) == "$arch" ]] || { echo "build $arch on an $arch machine" >&2; exit 2; }
march=
case $level in
  '') ;;
  v3) [[ $arch == x86_64 ]] || { echo "v3 is an x86_64 level" >&2; exit 2; }; march=-march=x86-64-v3 ;;
  *) echo "unknown level $level" >&2; exit 2 ;;
esac

jobs=$(nproc)
work=${WORK:-$(mktemp -d)}
mkdir -p "$work"
work=$(realpath "$work")
src=$work/src
prefix=$work/prefix
mkdir -p "$src" "$prefix"
export PKG_CONFIG_PATH=$prefix/lib/pkgconfig:$prefix/lib/$triple/pkgconfig:$prefix/share/pkgconfig
export PATH=$prefix/bin:$PATH
export CFLAGS="-O2 -fPIC -fno-semantic-interposition $march"
export CXXFLAGS=$CFLAGS
# Static libraries carry their own dependencies in Libs.private.
mkdir -p "$work/bin"
cat > "$work/bin/pkg-config-static" <<'EOS'
#!/bin/sh
exec pkg-config --static "$@"
EOS
chmod +x "$work/bin/pkg-config-static"

fetch() { # name url ref
  local dir=$src/$1
  [[ -d $dir/.git ]] && return
  if [[ $3 =~ ^[0-9a-f]{40}$ ]]; then
    # A commit: fetch just that one (GitHub serves any commit by hash).
    git init --quiet "$dir"
    git -C "$dir" fetch --quiet --depth 1 "$2" "$3"
    git -C "$dir" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    git -C "$dir" submodule update --quiet --init --recursive --depth 1
  else
    git -c advice.detachedHead=false clone --quiet --depth 1 --recurse-submodules --shallow-submodules --branch "$3" "$2" "$dir"
  fi
  echo "$1 $(git -C "$dir" describe --tags --always 2>/dev/null) $(git -C "$dir" rev-parse HEAD)" >> "$work/versions.txt"
}

meson_static() { # dir [options]
  local dir=$1; shift
  meson setup "$dir/build" "$dir" --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=static -Db_staticpic=true --wrap-mode=nodownload "$@"
  ninja -C "$dir/build" -j"$jobs"
  ninja -C "$dir/build" install
}
