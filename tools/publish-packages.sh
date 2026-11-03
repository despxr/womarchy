#!/usr/bin/env bash
# repo/ must first be fetched with fetch-signed-db.sh (signature + checksum checks).
# new/ contains artifacts from the isolated build job. Never log the signing secret.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${SIGNING_KEY_FPR:?}" "${SIGNING_KEY:?}" "${GH_REPO:?}" "${RELEASE:?}"
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
cleanup() {
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf "$GNUPGHOME"
}
trap cleanup EXIT
chmod 0700 "$GNUPGHOME"
printf '%s\n' "$SIGNING_KEY" | gpg --batch --import
unset SIGNING_KEY
gpg --list-secret-keys --with-colons | grep -q "fpr:::::::::$SIGNING_KEY_FPR:" ||
  { echo "wrong signing key" >&2; exit 1; }
sign() {
  gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --local-user "$SIGNING_KEY_FPR" --detach-sign "$1"
}

shopt -s nullglob
seeded=(repo/*.pkg.tar.zst)
new=(new/*.pkg.tar.zst)
((${#seeded[@]} > 0)) || { echo "no verified seed packages" >&2; exit 1; }
# Rebuild from scratch: repo-add must record the new signatures in %PGPSIG%, not
# retain the upstream signatures after we re-sign the package bytes.
rm -f repo/womarchy.*
for f in "${seeded[@]}"; do sign "$f"; done
repo-add -q -R repo/womarchy.db.tar.gz "${seeded[@]}"
for f in "${new[@]}"; do cp "$f" repo/; done
if ((${#new[@]})); then
  built=()
  for f in "${new[@]}"; do built+=("repo/${f##*/}"); done
  for f in "${built[@]}"; do sign "$f"; done
  repo-add -q -R repo/womarchy.db.tar.gz "${built[@]}"
fi

# Drop superseded seed files from the staging directory, not from release history.
listed=$(bsdtar -xOf repo/womarchy.db.tar.gz '*/desc' |
  awk '/^%FILENAME%$/ { getline; print }')
for f in repo/*.pkg.tar.zst; do
  if ! grep -qxF "${f##*/}" <<<"$listed"; then rm -f "$f" "$f.sig"; fi
done
rm -f repo/*.old
rm -f repo/womarchy.db repo/womarchy.files
cp repo/womarchy.db.tar.gz repo/womarchy.db
cp repo/womarchy.files.tar.gz repo/womarchy.files
for f in repo/womarchy.db repo/womarchy.db.tar.gz repo/womarchy.files repo/womarchy.files.tar.gz; do sign "$f"; done
bash "$ROOT/linux/packages/fetch-signed-db.sh" --verify-only repo

gh api "repos/$GH_REPO/releases" --paginate --jq '.[].tag_name' > releases.txt
if ! grep -qxF "$RELEASE" releases.txt; then
  gh release create "$RELEASE" --target main --prerelease \
    --title '[womarchy] signed fork package repository' \
    --notes 'Personal kineticz/womarchy repository. See docs/FORK-REPOSITORY.md on main for trust setup and verification.'
fi
# Upload package bytes/signatures before the database that references them.
gh release upload "$RELEASE" repo/*.pkg.tar.zst repo/*.pkg.tar.zst.sig --clobber
gh release upload "$RELEASE" repo/womarchy.db repo/womarchy.db.sig \
  repo/womarchy.db.tar.gz repo/womarchy.db.tar.gz.sig \
  repo/womarchy.files repo/womarchy.files.sig \
  repo/womarchy.files.tar.gz repo/womarchy.files.tar.gz.sig --clobber
echo "Published verified repository to $GH_REPO ($RELEASE)"
