"""First-run setup as discrete steps the GUI can show and drive.

Each step has check() -> (ok, detail) and, where we can do it ourselves, run(log, **args).
Steps the user has to do in Steam carry an `open` URL instead.
"""

import shutil
from pathlib import Path

from . import bridge, doctor, engine, gptk, launch, steamplay, vdf
from .util import APPID, GAMEFIXES, PAYLOAD, PFX_AION2, STEAM, lock


def _engine_pin():
    return lock()["bridge_engine"]


def _gptk_engine():
    return launch.bridge_engine()


# -- checks ------------------------------------------------------------------------------

def check_host():
    bad = [s for _, fn in (("macOS", doctor.check_macos), ("cpu", doctor.check_cpu))
           for ok, s, _ in [fn()] if not ok]
    ok, why, _ = doctor.check_rosetta()
    if not ok:
        bad.append("Rosetta is not installed")
    return not bad, "; ".join(bad) or "Apple Silicon, supported macOS, Rosetta"


def check_steam():
    ok, why, fix = doctor.check_steam()
    return ok, why if ok else fix


def check_engine():
    d = engine.engine_dir(_engine_pin())
    ok = (engine.wine_root(d) / "bin/wineserver").exists()
    return ok, f"Wine {_engine_pin()['tag']}" if ok else "not installed"


def check_gptk():
    d = engine.wine_root(_gptk_engine())
    ok = (d / "lib/external/D3DMetal.framework").exists() and (d / "lib/wine/x86_64-windows/d3d12.dll").exists()
    return ok, "D3DMetal imported" if ok else "drop Apple's Game Porting Toolkit .dmg here"


def check_steamplay():
    ok = steamplay.notproton_present()
    return ok, "Steam Play enabled in Steam.app" if ok else "Steam.app needs the Steam Play patch"


def check_compat_tool():
    run = steamplay.COMPAT_TOOL / "run"
    try:
        text = run.read_text()
    except OSError:
        return False, "not installed"
    from .util import REPO
    import sys
    ok = str(REPO) in text and sys.executable in text
    return ok, "registered with Steam" if ok else "points at an old install"


def check_bridge():
    miss = bridge.missing()
    return not miss, "Valve client files verified" if not miss else f"missing {', '.join(miss)}"


def check_fix():
    ok = (GAMEFIXES / "compat_cpuid.dylib").exists()
    return ok, "aion2-wine-compat installed" if ok else "needed: AION 2 hangs on the splash without it"


def check_prefix():
    ok = (PFX_AION2 / "system.reg").exists()
    return ok, "ready" if ok else "not created"


def _walk(d, *keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = next((v for kk, v in d.items() if kk.lower() == k.lower()), None)
    return d


def check_mapping():
    try:
        cfg = vdf.load(STEAM / "config/config.vdf")
    except OSError:
        return False, "Steam config not found"
    m = _walk(cfg, "InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping", APPID)
    name = m.get("name") if isinstance(m, dict) else None
    if name == "daeva":
        return True, "AION 2 runs with Daeva"
    return False, "In Steam: AION 2 → Properties → Compatibility → force “Daeva (winecx-gptk)”"


def check_game():
    ok, why, fix = doctor.check_game()
    return ok, "installed" if ok else fix


# -- actions -----------------------------------------------------------------------------

def run_engine(log, **_):
    pin = _engine_pin()
    tarball = PAYLOAD / "engine.tar.gz"
    if tarball.exists():
        log("verifying bundled engine")
        if engine.sha256(tarball) != pin["sha256"]:
            raise SystemExit("bundled engine failed its sha256 check")
    else:
        tarball = engine.fetch(pin)
    log("extracting Wine (about 1.3 GB)")
    d = engine.extract(pin, tarball)
    engine.dequarantine(d)


def run_gptk(log, dmg=None, **_):
    if not dmg:
        raise SystemExit("choose the Game Porting Toolkit .dmg")
    log("mounting and verifying Apple's signature")
    dst, files = gptk.import_gptk(Path(dmg), _engine_pin())
    log(f"imported D3DMetal ({len(files)} files)")


def run_steamplay(log, **_):
    log("quitting Steam (you stay signed in)")
    was = steamplay.quit_steam()
    try:
        steamplay.install_notproton(steamplay.payload())
    finally:
        if was:
            steamplay.run(["open", "-a", str(steamplay.STEAM_APP)])


def run_compat_tool(log, **_):
    steamplay.install_compat_tool()
    if steamplay.steam_running():
        log("restart Steam so it picks up the Daeva tool")


def run_bridge(log, **_):
    bridge.install(log)


def run_fix(log, **_):
    src = PAYLOAD / "compat_cpuid.dylib"
    if not src.exists():
        raise SystemExit("compat_cpuid.dylib is not in this build")
    GAMEFIXES.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, GAMEFIXES / "compat_cpuid.dylib")
    log("installed aion2-wine-compat")


def run_prefix(log, **_):
    log("creating the Windows prefix (first time takes a minute)")
    launch.ensure_prefix(_gptk_engine())


# id, title, check, run, open-url
STEPS = [
    ("host", "This Mac", check_host, None, None),
    ("steam", "Steam signed in", check_steam, None, "steam://open/main"),
    ("engine", "Wine engine", check_engine, run_engine, None),
    ("gptk", "Apple D3DMetal", check_gptk, run_gptk, "https://developer.apple.com/games/game-porting-toolkit/"),
    ("steamplay", "Steam Play", check_steamplay, run_steamplay, None),
    ("compat", "Daeva compatibility tool", check_compat_tool, run_compat_tool, None),
    ("bridge", "Steam client bridge", check_bridge, run_bridge, None),
    ("fix", "NC Guard CPUID fix", check_fix, run_fix, None),
    ("prefix", "Game prefix", check_prefix, run_prefix, None),
    ("game", "AION 2 installed", check_game, None, f"steam://install/{APPID}"),
    ("mapping", "Use Daeva for AION 2", check_mapping, None, f"steam://gameproperties/{APPID}"),
]

# a step's action needs these to be green first
NEEDS = {"gptk": ["engine"], "prefix": ["gptk", "bridge"]}


def status():
    out = []
    for sid, title, check, action, url in STEPS:
        try:
            ok, detail = check()
        except Exception as e:  # a crashed check is a red check
            ok, detail = False, f"check failed: {e}"
        out.append({"id": sid, "title": title, "ok": bool(ok), "detail": detail,
                    "can_run": action is not None, "open": url})
    return out


def run_step(sid, log, **args):
    for s, _, _, action, _ in STEPS:
        if s == sid and action:
            return action(log, **args)
    raise SystemExit(f"no runnable step {sid}")


def artwork():
    """AION 2 artwork from the local Steam library cache."""
    base = STEAM / "appcache/librarycache" / APPID
    found = {}
    for key, name in (("hero", "library_hero.jpg"), ("logo", "logo.png"), ("capsule", "library_capsule.jpg")):
        hit = next(iter(sorted(base.rglob(name))), None) if base.exists() else None
        if hit:
            found[key] = str(hit)
    return found
