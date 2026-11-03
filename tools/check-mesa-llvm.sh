#!/usr/bin/env bash
# Runs only in the disposable package build container, after makepkg installs Mesa.
# This is an ABI/linkage check, not a WSL GPU rendering test.
set -euo pipefail
export LC_ALL=C
repo=${1:?usage: check-mesa-llvm.sh PACKAGE_DIR}
for name in mesa vulkan-swrast; do
  shopt -s nullglob
  pkgs=("$repo/$name-"[0-9]*.pkg.tar.zst)
  ((${#pkgs[@]} == 1)) || { echo "expected one $name package" >&2; exit 1; }
  info=$(bsdtar -xOf "${pkgs[0]}" .PKGINFO)
  dep=$(awk '$1 == "depend" && $3 ~ /^libLLVM\.so=/ { print $3 }' <<<"$info")
  [[ -n $dep ]] || { echo "$name has no resolved LLVM soname dependency" >&2; exit 1; }
  pacman -T "$dep"
  echo "$name requires $dep (satisfied by the build snapshot)"
done
shopt -s nullglob
libs=(/usr/lib/libgallium-*.so /usr/lib/libvulkan_dzn.so /usr/lib/libvulkan_lvp.so)
((${#libs[@]} >= 3)) || { echo 'missing Mesa libraries' >&2; exit 1; }
for f in "${libs[@]}"; do
  [[ -f $f ]] || { echo "missing $f" >&2; exit 1; }
  linked=$(ldd "$f")
  if grep -q 'not found' <<<"$linked"; then printf '%s\n%s\n' "$f" "$linked" >&2; exit 1; fi
  echo "Library dependencies resolve: $f"
done
