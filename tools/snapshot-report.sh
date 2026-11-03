#!/usr/bin/env bash
# Disposable Arch container only. stdout is a compatibility report (empty means
# success); routine pacman output must not become a false rebuild-needed issue.
set -euo pipefail
export LC_ALL=C
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if ! pacman -Syyuu --noconfirm >"$log" 2>&1; then
  echo '- moving the container to the snapshot failed'
  echo '```'; tail -n 40 "$log"; echo '```'
elif ! pacman -S --noconfirm womarchy/aquamarine womarchy/hyprland womarchy/mesa \
    womarchy/vulkan-dzn womarchy/womarchy-session >"$log" 2>&1; then
  echo '- **our packages no longer install on this snapshot:**'
  echo '```'; tail -n 40 "$log"; echo '```'
else
  missing=$(
    for f in /usr/bin/Hyprland /usr/lib/libaquamarine.so /usr/lib/libgallium-*.so /usr/lib/libvulkan_dzn.so; do
      if linked=$(ldd "$f" 2>&1); then
        # grep returns 1 for a healthy library: that is not a shell error.
        if grep -q 'not found' <<<"$linked"; then
          grep 'not found' <<<"$linked" | sed "s|^|$f: |"
        fi
      else
        printf '%s: ldd failed: %s\n' "$f" "$linked"
      fi
    done
  )
  if [[ -n $missing ]]; then
    echo '- **libraries our packages need are gone from this snapshot:**'
    echo '```'; printf '%s\n' "$missing"; echo '```'
  fi
fi
