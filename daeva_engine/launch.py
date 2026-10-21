"""Capture Steam's launch of AION 2 and run it on the bridge engine.

Steam starts compatibilitytools.d/daeva/run, which calls `steam-run`. That records the
launch (argv + Steam env, 0600, 300 s TTL) and, unless a capture-only marker is set,
launches the game from inside Steam's process tree so Steam tracks it as running.
Nothing here touches the game install or its process beyond starting it.
"""

import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import bridge, engine
from .doctor import find_game
from .util import (APPID, CAPTURES, GAMEFIXES, LOGS, settings, PFX_AION2, lock, redact_arg, redact_env, redact_text,
                   run, write_private)

CAPTURE = CAPTURES / "launch.json"
CAPTURE_ONLY = CAPTURES / "capture-only"
# one-shot: next launch logs +loaddll
LOADDLL = CAPTURES / "loaddll"
COMPAT_CPUID = GAMEFIXES / "compat_cpuid.dylib"
TTL = 300
GAME_EXE = re.compile(r"(?i)(^|[\\/])aion2\.exe$")


def bridge_engine():
    d = engine.engine_dir(lock()["bridge_engine"])
    return d.with_name(d.name + "+gptk")


def _log(msg):
    LOGS.mkdir(parents=True, exist_ok=True)
    with open(LOGS / "steam-run.log", "a") as f:
        f.write(f"{time.strftime('%F %T')} {redact_text(msg)}\n")


def record(verb, argv):
    env = {k: v for k, v in os.environ.items() if k.startswith(("Steam", "STEAM_"))}
    cap = {"time": time.time(), "verb": verb, "argv": argv, "env": env}
    write_private(CAPTURE, json.dumps(cap))
    _log(f"captured verb={verb} argv={[redact_arg(a) for a in argv]} env={redact_env(env)}")
    return cap


def load_capture():
    try:
        cap = json.loads(CAPTURE.read_text())
    except (OSError, ValueError):
        return None
    if time.time() - cap["time"] > TTL:
        CAPTURE.unlink(missing_ok=True)
        return None
    return cap


def ensure_prefix(eng):
    wroot = engine.wine_root(eng)
    if not (PFX_AION2 / "system.reg").exists():
        PFX_AION2.parent.mkdir(parents=True, exist_ok=True)
        rc, out = engine.wine(wroot, PFX_AION2, "wineboot", "--init", timeout=900,
                              WINEDLLOVERRIDES="mscoree,mshtml=")
        engine.wineserver_kill(wroot, PFX_AION2)
        if not (PFX_AION2 / "system.reg").exists():
            raise SystemExit(f"wineboot failed: {redact_text(out[-500:])}")
    bridge.stage(PFX_AION2)


def game_argv(argv):
    for i, a in enumerate(argv):
        if GAME_EXE.search(a):
            return argv[i:]
    return None


def launch(cap):
    eng = bridge_engine()
    wroot = engine.wine_root(eng)
    argv = game_argv(cap["argv"])
    if not argv:
        raise SystemExit("capture has no AION2.exe in argv")
    exe = Path(argv[0])
    if not exe.is_absolute():
        g = find_game()
        exe = g[0] / "Aion2/Binaries/Win64/AION2.exe" if g else exe
    ensure_prefix(eng)

    env = dict(os.environ)
    env.update(cap["env"])
    env.update(bridge.env(eng, PFX_AION2, APPID))
    env.pop("DYLD_INSERT_LIBRARIES", None)
    prefs = settings()
    if LOADDLL.exists() or prefs["loaddll"]:
        LOADDLL.unlink(missing_ok=True)
        env["WINEDEBUG"] = "err+all,fixme-all,+loaddll"
    if prefs["metal_hud"]:
        env["MTL_HUD_ENABLED"] = "1"
    if prefs["msync"]:
        env["WINEMSYNC"] = "1"

    LOGS.mkdir(parents=True, exist_ok=True)
    logpath = LOGS / f"aion2-{time.strftime('%Y%m%d-%H%M%S')}.log"
    dos_exe = "Z:" + str(exe).replace("/", "\\")
    # aion2-wine-compat completes NC Guard's 64->32-bit CPUID trampoline, which Rosetta
    # can't run. Passed with arch -e because SIP strips DYLD_* from arch's environment.
    fix = []
    if COMPAT_CPUID.exists() and prefs["cpuid_fix"]:
        fix = ["-e", f"DYLD_INSERT_LIBRARIES={COMPAT_CPUID}"]
    cmd = ["arch", "-x86_64", *fix, str(wroot / "bin/wine"), bridge.STEAM_EXE, dos_exe, *argv[1:]]
    _log(f"launch {[redact_arg(a) for a in cmd]} cwd={exe.parent} log={logpath}")
    CAPTURE.unlink(missing_ok=True)

    proc = subprocess.Popen(cmd, env=env, cwd=exe.parent, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace")

    def stop(signum, _frame):
        proc.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        with open(logpath, "w") as log:
            os.chmod(logpath, 0o600)
            for line in proc.stdout:
                log.write(redact_text(line))
                log.flush()
        rc = proc.wait()
    finally:
        engine.wineserver_kill(wroot, PFX_AION2)
    _log(f"game exited rc={rc}")
    return rc


def steam_run(verb, argv):
    """Entry point for compatibilitytools.d/daeva/run."""
    if not game_argv(argv):
        # install-script evaluator and other helpers: nothing to do for this game
        _log(f"skip verb={verb} argv={[redact_arg(a) for a in argv]}")
        return 0
    cap = record(verb, argv)
    if CAPTURE_ONLY.exists():
        CAPTURE_ONLY.unlink()
        _log("capture-only: not launching")
        return 0
    return launch(cap)


def capture(timeout=120):
    CAPTURES.mkdir(parents=True, exist_ok=True)
    os.chmod(CAPTURES, 0o700)
    CAPTURE.unlink(missing_ok=True)
    write_private(CAPTURE_ONLY, "")
    run(["open", f"steam://rungameid/{APPID}"])
    end = time.time() + timeout
    while time.time() < end:
        cap = load_capture()
        if cap:
            print(f"captured verb={cap['verb']}")
            print("argv:", [redact_arg(a) for a in cap["argv"]])
            print("env:", json.dumps(redact_env(cap["env"]), indent=1))
            return 0
        time.sleep(1)
    CAPTURE_ONLY.unlink(missing_ok=True)
    print("no launch captured; is AION 2 mapped to the daeva compat tool?", file=sys.stderr)
    return 1


def play(loaddll=False):
    """Let Steam start the game through our compat tool (launches inside Steam's tree)."""
    CAPTURE_ONLY.unlink(missing_ok=True)
    if loaddll:
        write_private(LOADDLL, "")
    run(["open", f"steam://rungameid/{APPID}"])
    print(f"asked Steam to start {APPID}; follow with: daeva-engine logs")
    return 0


def launch_from_capture():
    cap = load_capture()
    if not cap:
        print(f"no capture younger than {TTL}s; run: daeva-engine capture", file=sys.stderr)
        return 1
    return launch(cap)


def recover():
    eng = bridge_engine()
    engine.wineserver_kill(engine.wine_root(eng), PFX_AION2)
    for p in (CAPTURE, CAPTURE_ONLY):
        p.unlink(missing_ok=True)
    print("wineserver killed for pfx-aion2, captures cleared")
    return 0


def running():
    return run(["pgrep", "-f", r"AION2\.exe"])[0] == 0


def logs(n=60):
    files = sorted(LOGS.glob("aion2-*.log"))
    for p in ([LOGS / "steam-run.log"] if (LOGS / "steam-run.log").exists() else []) + files[-1:]:
        print(f"== {p}")
        print("\n".join(p.read_text(errors="replace").splitlines()[-n:]))
    return 0
