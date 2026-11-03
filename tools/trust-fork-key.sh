#!/usr/bin/env bash
# Import only the pinned public signing key. Does not switch repos or install packages.
set -euo pipefail
export LC_ALL=C

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  echo 'Usage: bash tools/trust-fork-key.sh'
  echo 'Download, fingerprint-check and trust the kineticz/womarchy public key in pacman.'
  echo 'Run as your normal user; only pacman-key operations request sudo.'
  exit 0
fi
(($# == 0)) || { echo 'Unexpected arguments; use --help.' >&2; exit 2; }
for cmd in curl gpg awk mktemp mkdir rm pacman-key; do
  command -v "$cmd" >/dev/null || { echo "Missing required tool: $cmd" >&2; exit 1; }
done
root=()
if ((EUID != 0)); then
  command -v sudo >/dev/null || { echo 'Missing required tool: sudo' >&2; exit 1; }
  root=(sudo)
fi

expected=E0294A6FFD4CC7FF61F86F0BB0EE0B3F4029644C
url=https://raw.githubusercontent.com/kineticz/womarchy/main/linux/packages/womarchy-keyring/kineticz.asc
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -m 0700 "$work/gnupg"
key=$work/kineticz.asc
curl -fsSL --retry 3 "$url" -o "$key"
# Use an isolated public keyring, not ~/.gnupg. Reject additional primary keys,
# even when the expected key appears first; subkey fingerprints are ignored.
info=$(gpg --homedir "$work/gnupg" --batch --show-keys --with-colons "$key")
actual=$(awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }' <<<"$info")
if [[ $actual != "$expected" ]]; then
  echo "STOP: public key fingerprint mismatch (expected $expected). Nothing imported." >&2
  exit 1
fi

printf 'Verified signing fingerprint: %s\n' "$expected"
"${root[@]}" pacman-key --add "$key"
"${root[@]}" pacman-key --lsign-key "$expected"
echo 'Fork signing key imported and locally trusted.'
echo 'Repository configuration is unchanged; see docs/FORK-REPOSITORY.md for the next steps.'
