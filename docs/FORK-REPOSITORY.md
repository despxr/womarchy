# Personal signed package repository

This fork publishes to <https://github.com/kineticz/womarchy/releases/tag/packages>.
It is not the official womarchy repository. The repository name stays **womarchy**
so existing overlay hooks and the Mesa/LLVM guard continue to work.

## What is changed

- Mesa `1:26.2.3-2.2` rebuilds on the current Omarchy stable snapshot. Both Mesa
  and lavapipe record the actual LLVM soname as a dependency, resolved by makepkg.
- The build checks that the LLVM dependencies are satisfied and the installed
  Mesa libraries have no unresolved dynamic dependencies. This does **not** test
  GPU rendering: that still needs a disposable WSL installation with a GPU.
- Publication starts from the fork's current signed repository, or, on its first
  publication, the official signed repository. Existing database signatures,
  package signatures and package checksums are verified before using those files.
- Packages and the rebuilt database are signed with the fork's key. Upstream
  packages are mirrored, not rebuilt unless explicitly requested.
- The keyring retains the official public key and adds the fork's public key.
  The LLVM safety hook is not disabled or bypassed.

Fork signing fingerprint (check the complete value):

```text
E0294A6FFD4CC7FF61F86F0BB0EE0B3F4029644C
```

Public key: [kineticz.asc](../linux/packages/womarchy-keyring/kineticz.asc).
The signing key expires after two years; rotate it before then. The private key
exists only in the GitHub `womarchy-repo` environment secret
`WOMARCHY_REPO_SIGNING_KEY`, apart from the temporary RAM-only bootstrap keyring
that was deleted after uploading. It is not stored in Git or a local backup.
If the secret is lost, create a new key and explicitly migrate trust.

The environment accepts deployments from `main` only. Publication is manually
triggered by a repository maintainer; the fork does not claim to have an
additional human-reviewer approval gate. Build jobs never receive the secret.

## Building and verifying

```sh
gh workflow run packages.yml --repo kineticz/womarchy --ref main \
  -f packages='mesa-womarchy womarchy-keyring'
gh run list --repo kineticz/womarchy --workflow packages.yml
```

If publication fails after a successful build, reuse that run's artifacts with
current publication code instead of rebuilding (replace `RUN_ID`):

```sh
gh workflow run packages.yml --repo kineticz/womarchy --ref main \
  -f packages='' -f build_run_id=RUN_ID
```

Only artifacts from a successful `build` job of this repository's `packages`
workflow on `main` are accepted. Expired artifacts require a new build.

After a successful packages workflow, `snapshot-watch.yml` automatically checks
installation of the complete repository on the current snapshot, including the
mirrored Hyprland and aquamarine packages. It can also be run manually. If those
packages also need a rebuild, do that before switching a real installation.
Check the report and any `rebuild-needed` issue: a successful workflow that opened
such an issue means the repository is **not** compatible yet.

For an independent download/signature check (no installation):

```sh
mkdir -p out/fork-repo
WOMARCHY_REPO_URL=https://github.com/kineticz/womarchy/releases/download/packages \
  bash linux/packages/fetch-signed-db.sh --fetch-packages --prune out/fork-repo
```

## Switching an existing installation (manual, after testing)

Do **not** execute these steps until the build, publication, and complete snapshot
check succeed. Back up/export the WSL distro first. Test GPU rendering in a
throwaway distro before changing your working desktop. Do not ignore LLVM,
force dependencies, or disable the transaction hook to get past a failed check.

1. Download the public key from this fork, inspect its complete fingerprint with
   `gpg --show-keys --with-fingerprint`, and compare it with the value above through
   a trusted channel. Then import and locally trust that exact key in pacman:

   ```sh
   sudo pacman-key --add /path/to/verified/kineticz.asc
   sudo pacman-key --lsign-key E0294A6FFD4CC7FF61F86F0BB0EE0B3F4029644C
   ```

2. Use `sudoedit /etc/womarchy/config` to set the following, preserving the other
   settings and keeping only one `WOMARCHY_REPO_URL` entry:

   ```text
   WOMARCHY_REPO_URL=https://github.com/kineticz/womarchy/releases/download/packages
   ```

3. Reapply **only** the existing pacman leaf (not the whole system plan):

   ```sh
   sudo bash /usr/lib/womarchy/wsl/pacman.sh
   ```

   Check `/etc/pacman.conf`: `[womarchy]` must remain before `[core]`, the hosted
   server must point to the fork, and database signature checking must stay
   enabled. You can require signatures on both packages and databases with
   `SigLevel = PackageRequired DatabaseRequired`. The upstream overlay may reset
   this to `PackageOptional DatabaseRequired` later; the signed database still
   authenticates package checksums, and packages in this fork are signed too.

4. Perform a **full** update (`omarchy update`), not a partial Mesa/LLVM install.
   Review the transaction before agreeing. It must include the rebuilt Mesa and
   the fork keyring. Do not bypass another dependency or ABI warning.

To return to upstream, restore the original repository URL in the config, rerun
only the pacman leaf, and inspect a full update plan. A fork build's higher
release number may need an explicit downgrade once upstream has a compatible
build. Do not downgrade Mesa to the old LLVM build while LLVM 23.1 is installed.
