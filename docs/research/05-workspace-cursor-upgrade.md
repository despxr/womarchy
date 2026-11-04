# Workspace cursor warps: upstream and snapshot audit

Checked on 2026-11-03 before extending the Womarchy patch series. No installed packages or desktop
configuration were changed during the initial investigation. Later desktop validation and deployment
staging are recorded below.

## Version and dependency check

The project and the installed desktop use Hyprland **0.56.2** with Aquamarine **0.15.1**. The installed
Womarchy package revisions were `hyprland 0.56.2-4.6` and `aquamarine 0.15.1-1.9`.

Upstream's latest stable tags at inspection were Hyprland **0.57.1** (`acc1aa0bfd4bd575dcb0f76c35ccf12b660a1ab9`)
and Aquamarine **0.16.0** (`b77d67648336223a6c8fb88844ae316e7b72b574`). Hyprland's `main` was
`7cc61bc9a0b00ea90cfcb1055227f0937c527d32`.

The actual Omarchy snapshot databases, downloaded directly from `https://stable-mirror.omarchy.org`,
contain:

| Package | Snapshot version | Upgrade implication |
|---|---|---|
| hyprland | 0.56.2-4 | Still the project's pinned upstream version. |
| aquamarine | 0.15.1-1 | Still the project's pinned upstream version. |
| hyprutils | 0.14.2-1 | **Blocks Hyprland 0.57.1**, which requires >= 0.14.3. |
| hyprland-protocols | 0.8.0-1 | Meets 0.57.1's newly mandatory >= 0.8.0 requirement. |
| cmake | 4.4.4-1 | Meets Aquamarine 0.16.0's >= 3.27 requirement. |
| hyprwayland-scanner | 0.4.6-1 | Meets Aquamarine's >= 0.4.0 requirement. |
| wayland-protocols | 1.49-1 | Meets Hyprland's >= 1.49 requirement. |
| libcanberra | 1:0.30+r2+gc0620e4-6 | Newly required by Hyprland 0.57.1. |

Hyprland 0.57.1 also adds an sdbus-c++ build/link requirement for rtkit unless `NO_RTKIT` is set.
An eventual upgrade must update the Arch reference PKGBUILD and account for these dependencies,
not just change the tag in `patches/versions.sh`.

Aquamarine 0.16.0 changes its soname from **14 to 15**. The snapshot's Hyprland requires
`libaquamarine.so=14-64`; Aquamarine therefore cannot be upgraded independently on this desktop.
The snapshot's portal also depends on `libhyprutils.so=13-64`, so replacing Hyprutils outside the
snapshot requires a wider compatibility audit.

Database fingerprints for this observation:

- `core/os/x86_64/core.db`: `7015ab8595669a6c1e4e2fb6de64e0043c8eb99bb41be368417254078dabcd1e`
- `extra/os/x86_64/extra.db`: `6fe33bbb22b7e0eaef48ccc35b5896ee6612675b462373880b27cf58311b0a53`

## Patch applicability

Checked in separate, disposable worktrees at the newer tags; the active source forks were not rebased.
These checks cover patch application, not a complete newer-version build.

| Existing patch | Result against newer upstream |
|---|---|
| Aquamarine 0001: shm allocator | Applies to 0.16.0. |
| Aquamarine 0002: WSL backend | Applies after 0001; its Wsl.cpp passes C++23 syntax checking with the snapshot headers. |
| Hyprland 0001: DRM-free rendering | Does not apply cleanly to 0.57.1; renderer changes require rebasing. |
| Hyprland 0002: select WSL backend | Does not apply cleanly; `src/debug/HyprCtl.cpp` has moved. |
| Hyprland 0003: CPU cursor buffers | Does not apply cleanly; the cursor rendering code has changed. |
| Hyprland 0004: capture without dmabuf | Applies to 0.57.1. |
| Hyprland 0005: absolute motion per output | Already implemented upstream, including additional transform handling; remove on upgrade. |

**Decision:** keep Hyprland 0.56.2 and Aquamarine 0.15.1 until the dependency stack is available in
Omarchy's snapshot and the renderer patches have been rebased and tested. Do not lower upstream's
minimum dependency requirements to force an upgrade.

## The cursor bug is a separate Womarchy integration gap

The reported case has workspace 1 and workspace 2 on different monitors. Super+1 changes Linux's
focus and pointer position, but the real Windows cursor stays on workspace 2's monitor. Subsequent
Windows pointer motion can put Linux's pointer back there.

`CPointerController::warpTo` is identical in the pinned 0.56.2, stable 0.57.1, and the inspected
upstream `main`. The Womarchy WSL backend's `CWslOutput::moveCursor` intentionally does nothing:
normal input already moves the host cursor. The protocol previously had cursor images/visibility,
but no compositor-to-viewer pointer-warp message. An upstream upgrade alone does not supply this
missing Womarchy protocol integration.

The smallest explicit-warp fix keeps that normal-motion behavior:

1. Only `CPointerController::warpTo` notifies a WSL output, after the existing `cursor:no_warps` guard
   and the pointer manager's layout clamping. Other backends are unchanged.
2. Reuse Hyprland's cursor-coordinate helper for output-local physical pixels, including scale and
   output transform; do not subtract the cursor-image hotspot.
3. Aquamarine sends a new, additive `WDP_POINTER_WARP` message with output id and two doubles.
   Protocol version 2 remains compatible: old viewers ignore the unknown message.
4. The viewer validates coordinates, resolves the output's client area to Windows screen coordinates,
   and calls `SetCursorPos` on the UI thread only while the authenticated viewer is live, foreground,
   and the target window is visible and not minimized.
5. The resulting Windows mouse move goes through the existing input path. Normal motion and
   cursor-plane updates do not emit another warp, so there is no feedback loop.

The new Hyprland package requires **aquamarine >= 0.15.1-1.10**, in addition to its soname dependency:
the new method is an extra library symbol even though the ABI soname is unchanged. Rebuild both
packages and the Windows viewer. Old viewers remain usable but will not gain the fix.

## Validation and remaining desktop check

Automated coverage includes:

- Rust parsing: packed little-endian fields, truncated payloads, NaN/infinity, invalid ids/coordinates,
  monitor bounds, fractional positions, transformed boundaries, and compatible trailing fields.
- An isolated AF_UNIX WSL backend with two outputs and an authenticated fake viewer: explicit warps
  reach the correct output; normal motion and an incoming echo generate no outgoing warp.
- C++23 syntax checks of the modified backend and Hyprland pointer controller against snapshot headers.
- Package-generation regressions: deterministic PKGBUILD output, required Aquamarine revision, and
  fail-closed handling of missing/changed runtime dependencies.
- Windows-target clippy, including all test targets.

The backend smoke test can be run **without installing the new library** when the installed
Aquamarine has the same pinned base version (0.15.1). Link the patched WSL implementation into the
test executable; the other backend/allocator code comes from the installed library:

```bash
tools/setup-src.sh
c++ -std=c++23 -O1 -Iprotocol -Isrc/aquamarine/include -Isrc/aquamarine/src/include \
  $(pkg-config --cflags aquamarine hyprutils libdrm libinput wayland-client gbm pixman-1) \
  lab/pointer-warp-test.cpp src/aquamarine/src/backend/Wsl.cpp \
  $(pkg-config --libs aquamarine hyprutils libdrm libinput wayland-client gbm pixman-1) \
  -o /tmp/womarchy-pointer-warp-test
timeout 15 /tmp/womarchy-pointer-warp-test
```

A full local Windows `cargo test --release --locked` attempt was blocked by Windows refusing to
execute Cargo dependency build scripts (`Access denied`). No Windows security settings were changed.
The Windows CI build/tests/clippy subsequently passed, and the tested binary was retrieved from its
artifact. The package build also passed against Omarchy's snapshot on a non-main test branch;
publication was skipped.

After installing the rebuilt packages and viewer in a **test session**, verify:

- Put workspace 1 and workspace 2 on different monitors, ideally with mixed DPI.
- With the pointer on workspace 2, press Super+1: focus and the real Windows cursor must both reach
  workspace 1. Move the mouse slightly: it must not jump back. Repeat in both directions.
- Check another explicit keyboard warp, and ordinary mouse movement across monitors.
- Check `cursor:no_warps`: non-forced warps must remain disabled.
- With a different Windows application foreground, or a target viewer minimized, the viewer must
  not relocate the host cursor.

## Desktop validation and deployment staging

The built package artifacts are Aquamarine `0.15.1-1.10` and Hyprland `0.56.2-4.7` from
[package build 41715411593](https://github.com/kineticz/womarchy/actions/runs/41715411593).
They installed successfully in `omarchy-test-pointer`, prepared from the SHA256-verified v0.2.0
release image. All libraries required by the new compositor resolve on both that distro and the
running desktop.

The final Windows viewer was tested from the host owner's approved `code/bin/womarchy.exe`
location. Defender's executable-reputation ASR rule blocked repeat execution from the temporary
folder; no Defender or other security settings were changed. A concurrent second `omarchy.exe`
did not receive Win-key input on this host, whereas the byte-identical viewer under a distinct name
did. The keyboard-hook module experiment did not solve that difference and was reverted; the
underlying host-specific name interaction is not yet diagnosed. The distinct final filename was
therefore retested, not merely copied after testing another name.

Results with the final filename:

- **21 windowed integration checks passed:** two outputs at scales 1.25 and 1.0; three cycles of
  Win+1/Win+2 through the Windows keyboard hook; physical cursor coordinates; small subsequent mouse
  movements; normal cross-output motion; `no_warps`; forced warps; minimized/hidden targets;
  foreground application protection; rendering, configuration validation, and clean viewer exit.
- **19 fullscreen checks passed:** Windows reported only one active physical display at test time,
  so both workspaces were exercised on that screen at scale 1.25. Fullscreen two-physical-monitor
  testing remains conditional on reconnecting the second display; no display settings were changed.
- **12 isolated real-compositor checks passed:** authenticated inline frames, two mixed-scale
  outputs, real Hyprland keybindings, exact outgoing warp coordinates, echo/no-motion feedback checks,
  `no_warps`, forced movement, screenshots, and clean compositor exit.

The tests are [pointer-warp-desktop-test.ps1](../../lab/pointer-warp-desktop-test.ps1) and
[pointer-warp-hyprland-test.py](../../lab/pointer-warp-hyprland-test.py). Screenshots/logs stay local,
not in the repository. The temporary distro is stopped after use.

Deployment staging: the new Windows viewer is in the approved `code/bin` folder, and the existing
Omarchy Start-menu shortcut targets it. Previous viewer/shortcut and both old package archives were
saved for rollback. After the owner authorized a new interactive sudo prompt, Aquamarine
`0.15.1-1.10` and Hyprland `0.56.2-4.7` installed successfully on the everyday desktop. Package
integrity checks reported no altered files and all linked libraries resolve. The owner also approved
the session restart. A one-time Windows maintenance task is used because the Linux terminal/agent
belongs to the graphical session that will stop; the task validates the new process, rendering, and
actual desktop cursor synchronization, records its result locally, and deletes its registration.
