#!/usr/bin/env bash
# Applies this fork's machine profile to an installed Omarchy (WSL) distro.
#
# Run inside the Omarchy distro as your normal user (NOT with sudo):
#
#     bash machine/apply-machine.sh
#
# Idempotent: safe to re-run, and safe to re-run after `omarchy update` (which
# re-provisions ~/.config/hypr/womarchy.lua but leaves bindings.lua alone).
# Touches only your user config; no packages, no repositories, no sudo.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
hypr="$cfg/hypr"

if [[ $EUID -eq 0 ]]; then
  echo "apply-machine.sh: run as your normal user, not root (it writes ~/.config)" >&2
  exit 1
fi

if [[ ! -d $hypr ]]; then
  echo "apply-machine.sh: $hypr not found. Is this the Omarchy distro?" >&2
  echo "  Install womarchy first, then re-run this script inside it." >&2
  exit 1
fi

install -d -m 0755 "$hypr"
install -m 0644 "$here/machine.lua" "$hypr/machine.lua"

bindings="$hypr/bindings.lua"
touch "$bindings"
if ! grep -q 'require("hypr.machine")' "$bindings"; then
  cat >>"$bindings" <<'EOF'

-- Machine profile (laptop iGPU, 3 x 1920x1200). See ~/.config/hypr/machine.lua.
require("hypr.machine")
EOF
  echo "added require(\"hypr.machine\") to $bindings"
else
  echo "require(\"hypr.machine\") already present in $bindings"
fi

echo "installed $hypr/machine.lua"

if command -v hyprctl >/dev/null 2>&1 && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null && echo "reloaded the running session"
else
  echo "not in a running session; the profile applies on next login"
fi
