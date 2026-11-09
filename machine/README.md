# machine/ — this fork's profile for one laptop

Tuning for **Lenovo laptop, Ryzen AI 7 PRO 350, Radeon 860M (iGPU),
3 x 1920x1200 @ 100% scale, Windows 11 build 26300**.

This is not a new installable distro. It is a profile applied to an Omarchy
distro after it is installed. See [../docs/OUR-FORK.md](../docs/OUR-FORK.md) for
why, and for the install order.

## Files

| File | What it does |
|---|---|
| `machine.lua` | Hyprland settings that pay for themselves on an iGPU laptop. Installed to `~/.config/hypr/machine.lua`. |
| `apply-machine.sh` | Copies `machine.lua` into place and requires it from `bindings.lua`. Idempotent, user-level, no sudo. |
| `use-kineticz-repo.sh` | **Opt-in and trust-sensitive.** Switches the package repo to the kineticz fork, which carries the Mesa rebuild for upstream issue #6. |
| `wslconfig.example` | Global WSL memory cap. Copy to `%UserProfile%\.wslconfig` by hand. |

## What is tuned, and why

| Setting | Reason |
|---|---|
| `misc:vfr = true` | The desktop is mostly static. Variable frame rate is the biggest idle power win on a laptop. |
| `decoration:shadow:enabled = false` | Per-window shadows are the cheapest large cost to drop; barely visible at 100% scale. |
| `decoration:blur:passes = 2` | Keeps Omarchy's look, cuts roughly a third of the blur cost. `size` is untouched. |
| `misc:disable_hyprland_logo`, `disable_splash_rendering` | Skip two draws on every session start. |
| `.wslconfig memory=16GB`, `autoMemoryReclaim=gradual` | Stops the desktop from holding all 27 GB and starving Windows. |

**Deliberately not tuned:**

- **Monitor rules.** `womarchy-session` generates them from the Windows layout
  (mode, position, scale per output) into `$XDG_RUNTIME_DIR/womarchy/monitors.lua`,
  and `~/.config/hypr/monitors.lua` `dofile()`s that. Hardcoding outputs here
  would fight the Windows layout every time a monitor is plugged in.
- **`GALLIUM_DRIVER` / `GSK_RENDERER`.** Already set correctly by
  `linux/overlay/wsl/gpu.sh` and the `60-womarchy-gpu` user environment
  generator, but only when `/dev/dxg` exists. `MESA_D3D12_DEFAULT_ADAPTER_NAME`
  is deliberately unset (first adapter) — correct here, there is one GPU.
- **Animations.** `womarchy-provision-user` already removes Omarchy's
  `no-animations` toggle when it verifies d3d12 rendering with `eglinfo`. On this
  machine they should stay on; disabling them is a UX regression, not an
  optimisation.

## Usage

Inside the Omarchy distro, as your normal user:

```sh
bash machine/apply-machine.sh          # tuning only
bash machine/use-kineticz-repo.sh      # opt-in: Mesa fix, asks first
```

Re-run `apply-machine.sh` after `omarchy update` if you want the profile
reasserted. It is idempotent.

## Caveats

- The Lua is written against the same `hl.config({...})` API that
  `linux/overlay/user/hypr/womarchy.lua` uses, but it has **not been executed on
  a running Hyprland session** — there is no Omarchy install on this machine yet.
  If a key is rejected, Hyprland logs it at startup; check
  `~/.local/share/hyprland/hyprland.log`.
- `blur:passes` and `shadow:enabled` override Omarchy's theme values. If a theme
  looks wrong, comment those two lines out and re-run.
