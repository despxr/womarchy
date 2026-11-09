# This fork

Personal fork of [sytelus/womarchy](https://github.com/sytelus/womarchy) for one
machine: a Lenovo laptop with a Ryzen AI 7 PRO 350, Radeon 860M, three 1920x1200
displays at 100% scale, Windows 11.

It is **`kineticz/womarchy` plus a machine profile**. Nothing here is a rewrite.

## What is in it

| Layer | Source | Why |
|---|---|---|
| Upstream womarchy | `sytelus/womarchy` @ 2026-10-01 | The actual project. Unmaintained since then. |
| kineticz's 13 commits | `kineticz/womarchy` | Rebuilt Mesa against current LLVM (fixes upstream #6), signed fork package repo, cursor-warp sync. |
| `machine/` | this fork | Hyprland + WSL tuning for the hardware above. |

`fork` is a strict superset of `origin/main`: `git rev-list --count
origin/main..fork` is 13 before the machine commits.

## Why this is not an installable fork

`install.ps1` downloads `omarchy.exe` and `Omarchy.wsl` from a **release**. The
kineticz fork publishes only a `packages` release — there is no image and no
`omarchy.exe`:

```
sytelus/womarchy   v0.2.0   install.ps1, omarchy.exe, Omarchy.wsl
kineticz/womarchy  packages only (mesa 1.26.2.3-2.2 rebuilt)
```

Producing an installable fork means building the Arch rootfs image and the
Rust/Windows viewer, then publishing them — a CI job with signing secrets, not a
local edit. So this fork is applied **after** a normal install.

## Install order

```powershell
# 1. Install from upstream (the only source of image + exe).
irm https://raw.githubusercontent.com/sytelus/womarchy/main/install.ps1 | iex
```

```sh
# 2. Inside the Omarchy distro, from a checkout of THIS fork:

#    tuning only — safe, user-level, no sudo
bash machine/apply-machine.sh

#    opt-in: the Mesa/LLVM fix. Asks first; trusts a third-party signing key.
bash machine/use-kineticz-repo.sh
```

Step 2b is optional at first. Upstream's Mesa/LLVM guard
(`linux/overlay/hooks/10-womarchy-mesa-llvm.hook`) **aborts** a transaction that
would break Mesa rather than leaving a broken desktop — so an unpatched install
refuses to update past the LLVM bump instead of silently breaking. Run 2b when
you actually want to take updates again.

## Trust model

- `use-kineticz-repo.sh` imports the fork key pinned to its **full fingerprint**
  (`E0294A6FFD4CC7FF61F86F0BB0EE0B3F4029644C`) via `tools/trust-fork-key.sh`,
  which uses an isolated keyring and rejects extra primary keys.
- After that, packages in `[womarchy]` are built and signed by kineticz, not by
  the upstream author. The repository name stays `womarchy` so the overlay hooks
  and the LLVM guard keep working.
- The private signing key exists only in kineticz's GitHub environment secret.
  This fork cannot publish packages, and does not try to.
- To leave: restore
  `WOMARCHY_REPO_URL=https://github.com/sytelus/womarchy/releases/download/packages`,
  re-run `sudo bash /usr/lib/womarchy/wsl/pacman.sh`, and inspect a full update
  plan. A fork build's higher `pkgrel` may need an explicit downgrade once
  upstream ships a compatible Mesa.

## Updating from kineticz

```sh
git fetch kineticz
git rebase kineticz/main      # machine/ commits replay on top
```

`machine/` only adds files and one `require` line, so rebases should stay clean.

## What is not done here

- No image rebuild, so `linux/overlay/` changes in this branch are **not** in the
  installed distro unless the image is rebuilt. `machine/` exists precisely
  because of that.
- No independent GPU verification. The Mesa rebuild is checked for ABI/linkage
  (`tools/check-mesa-llvm.sh`), not for rendering.
- The machine profile has not run on a live Hyprland session.
