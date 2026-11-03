#!/usr/bin/env python3
"""Real patched Hyprland + WSL backend, with an authenticated AF_UNIX fake viewer.

No Windows cursor or everyday session is touched. Run only in a test distro.
Exercises actual keybindings, mixed-scale coordinates, echoes, and no_warps.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import queue
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time


def wait_for(condition, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.05)
    raise RuntimeError("test condition timed out")


def main():
    if not os.environ.get("WSL_DISTRO_NAME", "").startswith("omarchy-test"):
        raise SystemExit("Run only in an omarchy-test* distro, never the everyday desktop")
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    # Hyprland's instance signature is long; keep its AF_UNIX IPC paths below 108 bytes.
    with tempfile.TemporaryDirectory(prefix="ww-") as tmp:
        root = Path(tmp)
        runtime = root / "r"
        runtime.mkdir(mode=0o700)
        address = str(root / "display.sock")
        token = os.urandom(32)
        env = dict(os.environ)
        for name in ("WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "WOMARCHY_SHM_DIR"):
            env.pop(name, None)
        env.update(XDG_RUNTIME_DIR=str(runtime), HYPRLAND_BACKEND="wsl", GALLIUM_DRIVER="d3d12",
                   WOMARCHY_LISTEN_UNIX=address, WOMARCHY_TOKEN=token.hex(), WOMARCHY_ORPHAN_TIMEOUT="30",
                   WOMARCHY_MONITORS="1:0:0:800:600:60000:1250:1:one;2:800:0:800:600:60000:1000:0:two")
        conf = root / "hyprland.conf"
        conf.write_text("""monitor = WSL-1,800x600,0x0,1.25
monitor = WSL-2,800x600,640x0,1
workspace = 1,monitor:WSL-1,default:true,persistent:true
workspace = 2,monitor:WSL-2,default:true,persistent:true
misc:disable_hyprland_logo = true
misc:disable_splash_rendering = true
animations:enabled = false
cursor:warp_on_change_workspace = 1
cursor:no_warps = false
bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
""")
        log = (args.output / "hyprland.log").open("w")
        proc = subprocess.Popen(["Hyprland", "--config", str(conf)], env=env, stdout=log,
                                stderr=subprocess.STDOUT, start_new_session=True)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        warps = queue.Queue()
        frames = Counter()
        errors = []
        stop = threading.Event()
        send_lock = threading.Lock()
        reader = None

        def send(kind, payload=b""):
            with send_lock:
                sock.sendall(struct.pack("<II", kind, len(payload)) + payload)

        def exact(size):
            data = bytearray()
            while len(data) < size:
                block = sock.recv(size - len(data))
                if not block:
                    raise EOFError("display socket closed")
                data.extend(block)
            return bytes(data)

        def receive():
            try:
                while not stop.is_set():
                    kind, size = struct.unpack("<II", exact(8))
                    assert size <= 64 << 20
                    data = exact(size)
                    if kind == 103:  # FRAME; acknowledge it without touching a Windows/shared-memory mapping
                        output = struct.unpack_from("<I", data)[0]
                        seq = struct.unpack_from("<Q", data, 20)[0]
                        frames[output] += 1
                        send(3, struct.pack("<IIQQ", output, 0, seq, 0))
                    elif kind == 105:
                        assert len(data) == 20
                        warps.put(struct.unpack("<Idd", data))
                    elif kind == 110:
                        return
            except (EOFError, OSError) as exc:
                if not stop.is_set():
                    errors.append(str(exc))
            except Exception as exc:
                errors.append(repr(exc))

        def ctl(*arguments, decode=False):
            result = subprocess.run(["hyprctl", *arguments], env=env, capture_output=True, text=True, timeout=10)
            if result.returncode:
                raise RuntimeError(result.stderr or result.stdout)
            return json.loads(result.stdout) if decode else result.stdout

        def clear_warps():
            time.sleep(0.15)
            while not warps.empty():
                warps.get_nowait()

        def pointer(output, x, y):
            send(11, struct.pack("<IIdd", 1, output, x, y))
            send(15)

        def key(workspace):
            for code, down in ((125, 1), (workspace + 1, 1), (workspace + 1, 0), (125, 0)):
                send(10, struct.pack("<III", 1, code, down))
                time.sleep(0.02)

        def check_warp(output):
            warp = wait_for(lambda: warps.get_nowait() if not warps.empty() else None)
            assert warp[0] == output, (warp, output)
            monitor = next(m for m in ctl("-j", "monitors", decode=True) if m["name"] == f"WSL-{output}")
            pos = ctl("-j", "cursorpos", decode=True)
            expected = ((pos["x"] - monitor["x"]) * monitor["scale"],
                        (pos["y"] - monitor["y"]) * monitor["scale"])
            assert all(abs(a - b) <= 1.5 for a, b in zip(warp[1:], expected)), (warp, expected)
            assert monitor["focused"]
            # The host's synthesized absolute motion must not provoke another outgoing warp.
            clear_warps()
            pointer(*warp)
            time.sleep(0.25)
            assert warps.empty(), "host echo caused a warp feedback loop"
            return warp

        def passed(name):
            results.append({"test": name, "passed": True})
            print("PASS:", name, flush=True)

        try:
            wait_for(lambda: Path(address).exists() or proc.poll() is not None)
            assert proc.poll() is None, "Hyprland exited at startup; see hyprland.log"
            sock.connect(address)
            sock.settimeout(20)
            send(1, struct.pack("<I16sI", 2, token[:16], 1 << 1))
            kind, size = struct.unpack("<II", exact(8))
            welcome = exact(size)
            assert kind == 100 and struct.unpack_from("<II", welcome) == (2, 1)
            assert welcome[48:64] == token[16:], "compositor authentication failed"
            reader = threading.Thread(target=receive, daemon=True)
            reader.start()
            instance = wait_for(lambda: next((runtime / "hypr").glob("*/.socket.sock"), None))
            env["HYPRLAND_INSTANCE_SIGNATURE"] = instance.parent.name
            env["WAYLAND_DISPLAY"] = wait_for(lambda: next((p.name for p in runtime.glob("wayland-*")
                                                            if not p.name.endswith(".lock")), None))
            assert not ctl("configerrors").strip(), "minimal test config has errors"
            wait_for(lambda: frames[1] and frames[2])
            passed("real GPU frames and authenticated inline transport on both outputs")
            for output in (1, 2):
                ctl("dispatch", "exec", f"[workspace {output} silent] foot --title WomarchyWarp{output}")
            wait_for(lambda: len([c for c in ctl("-j", "clients", decode=True)
                                 if c["initialTitle"].startswith("WomarchyWarp")]) == 2)
            for cycle in range(3):
                for output in (1, 2):
                    pointer(3 - output, 100, 100)
                    time.sleep(0.15)
                    clear_warps()
                    key(output)
                    warp = check_warp(output)
                    assert ctl("-j", "activeworkspace", decode=True)["id"] == output
                    passed(f"Super+{output}, exact mixed-scale host warp and echo (cycle {cycle + 1})")
                    pointer(output, warp[1] + 2, warp[2] + 2)
                    time.sleep(0.15)
                    assert warps.empty()
            passed("ordinary absolute input emits no host warps")
            pointer(2, 100, 100)
            time.sleep(0.15)
            ctl("keyword", "cursor:no_warps", "true")
            clear_warps()
            key(1)
            time.sleep(0.25)
            assert warps.empty(), "no_warps was ignored"
            passed("no_warps suppresses non-forced keyboard warps")
            ctl("dispatch", "movecursor", "320 240")
            check_warp(1)
            passed("forced movecursor still synchronizes with no_warps enabled")
            for output in (1, 2):
                shot = args.output / f"output-{output}.png"
                subprocess.run(["grim", "-o", f"WSL-{output}", str(shot)], env=env, check=True, timeout=15)
                assert shot.stat().st_size > 1000
            passed("screenshots of both rendered outputs")
            assert not errors, errors
            ctl("dispatch", "exit")
            proc.wait(timeout=10)
            assert proc.returncode == 0, proc.returncode
            passed("clean compositor exit")
        finally:
            stop.set()
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
            if reader:
                reader.join(timeout=2)
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            log.close()
            (args.output / "results.json").write_text(json.dumps({"tests": results, "frames": dict(frames)}, indent=2))


if __name__ == "__main__":
    main()
