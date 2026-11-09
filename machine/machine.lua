-- womarchy machine profile: Lenovo laptop, Ryzen AI 300, Radeon 860M (iGPU).
-- Displays: 3 x 1920x1200 @ 100% scale (96 DPI), Windows 11.
--
-- Installed to ~/.config/hypr/machine.lua by machine/apply-machine.sh and
-- required from ~/.config/hypr/bindings.lua. Overwritten on re-apply, so keep
-- personal changes in another file and require it after this one.
--
-- Only settings that pay for themselves on this hardware are here. Monitor
-- rules are NOT set: womarchy-session generates them from the Windows layout
-- (mode, position and scale per output) into $XDG_RUNTIME_DIR/womarchy/monitors.lua,
-- and ~/.config/hypr/monitors.lua dofile()s that. Overriding them here would
-- fight the Windows layout on every monitor change.

-- Guard: this file is also loaded by tooling that has no Hyprland API.
if type(hl) ~= "table" or type(hl.config) ~= "function" then
  return
end

hl.config({
  misc = {
    -- Laptop power: composite at the rate the screen needs, not a fixed 60 Hz.
    -- The desktop is mostly static, so this is the single biggest idle win.
    vfr = true,
    -- No VRR: the WSL backend presents fixed-rate frames to omarchy.exe.
    vrr = 0,
    -- Skip the logo/splash draws on every session start.
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },
  decoration = {
    -- Shadows are drawn per window on the CPU-side compositor path and are the
    -- cheapest large win to drop; the visual difference at 100% scale is small.
    shadow = { enabled = false },
    blur = {
      -- Keep Omarchy's look, halve the cost. `passes` is the cost multiplier
      -- (default 3); `size` is left at Omarchy's value so the look is unchanged.
      enabled = true,
      passes = 2,
      new_optimizations = true,
      xray = true,
      ignore_opacity = true,
    },
  },
})

-- To trade the last bit of GPU headroom for a plainer desktop, uncomment:
-- hl.config({ decoration = { blur = { enabled = false }, rounding = 0 } })
