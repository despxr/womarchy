#!/usr/bin/env bash
# Opt-in: point an installed Omarchy distro at the kineticz fork's signed package
# repository, which carries the Mesa rebuild that fixes upstream issue #6
# ("llvm-libs upgrade removes libLLVM.so.22.1").
#
# Run inside the Omarchy distro as your normal user (NOT with sudo):
#
#     bash machine/use-kineticz-repo.sh
#
# This is the trust-sensitive step, so it is separate from apply-machine.sh and
# asks before changing anything. It automates docs/FORK-REPOSITORY.md:
#   1. import the fork's public key, pinned to its full fingerprint;
#   2. set WOMARCHY_REPO_URL in /etc/womarchy/config;
#   3. reapply the pacman leaf and show the update plan.
# It does not install anything on its own; step 4 leaves the full update to you.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
repo_url="https://github.com/kineticz/womarchy/releases/download/packages"
fpr="E0294A6FFD4CC7FF61F86F0BB0EE0B3F4029644C"

if [[ $EUID -eq 0 ]]; then
  echo "use-kineticz-repo.sh: run as your normal user, not root" >&2
  echo "  (it asks for sudo only for the two pacman-key steps and the config edit)" >&2
  exit 1
fi

if [[ ! -f /etc/womarchy/config ]]; then
  echo "use-kineticz-repo.sh: /etc/womarchy/config not found. Is this the Omarchy distro?" >&2
  exit 1
fi

cat <<EOF
This will switch this distro's [womarchy] package repository to:

  $repo_url

signed by the kineticz fork key:

  $fpr

That means installing packages built and signed by a third party (not the
upstream womarchy author). The repository name stays "womarchy" so the existing
overlay hooks and the Mesa/LLVM guard keep working. Back up the distro first:

  omarchy backup

EOF
read -r -p "Continue? [y/N] " answer
[[ $answer =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Nothing was changed."; exit 0; }

echo
echo "==> 1/3 trusting the fork key"
bash "$root/tools/trust-fork-key.sh"

echo
echo "==> 2/3 setting WOMARCHY_REPO_URL"
if grep -qs '^WOMARCHY_REPO_URL=' /etc/womarchy/config; then
  sudo sed -i "s|^WOMARCHY_REPO_URL=.*|WOMARCHY_REPO_URL=$repo_url|" /etc/womarchy/config
else
  printf '\nWOMARCHY_REPO_URL=%s\n' "$repo_url" | sudo tee -a /etc/womarchy/config >/dev/null
fi
grep -n '^WOMARCHY_REPO_URL=' /etc/womarchy/config

echo
echo "==> 3/3 reapplying the pacman leaf"
sudo bash /usr/lib/womarchy/wsl/pacman.sh

cat <<'EOF'

Done. Now review a full update by hand (do not use a partial install):

    omarchy update

The transaction must include the rebuilt Mesa and the fork keyring. Do not
bypass a dependency or ABI warning to get past a failed check.

To return to upstream later: restore the original WOMARCHY_REPO_URL
(https://github.com/sytelus/womarchy/releases/download/packages), re-run
`sudo bash /usr/lib/womarchy/wsl/pacman.sh`, and inspect a full update plan.
EOF
