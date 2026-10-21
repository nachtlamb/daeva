"""Enable Steam Play in macOS Steam with NotProton's dylib, and register the daeva compat tool.

Mirrors NotProton v1.2.0 SteamInstaller.swift (copy dylib, back up Info.plist, set
LSEnvironment, ad-hoc re-sign, lsregister, signatures) without its CrossOver runner and
bridge staging, which this project replaces.
"""

import hashlib
import sys
import plistlib
import shutil
import subprocess
import time
import zipfile
from pathlib import Path

from .util import DAEVA, REPO, STEAM, run

STEAM_APP = Path("/Applications/Steam.app")
NP_SUPPORT = Path.home() / "Library/Application Support/notproton"
NP_ZIP_URL = "https://github.com/NotProtonNot/NotProton/releases/download/v1.2.0/NotProton.zip"
NP_ZIP_SHA256 = "c077473daae9a049a51dd039a2908c7c061f630d58628a74ac4e8a9f6e5b2e09"
NP_PAYLOAD = "NotProton.app/Contents/Resources/NotProtonApp_NotProtonApp.bundle/Contents/Resources/payload"
INSERT_KEY = "DYLD_INSERT_LIBRARIES"
CONTROLLER_KEY, CONTROLLER_VALUE = "SDL_JOYSTICK_BLACKLIST_DEVICES", "0x05ac/0x0004"
COMPAT_TOOL = STEAM / "compatibilitytools.d/daeva"


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def payload():
    """Fetch and unpack the pinned NotProton release; return the payload dir."""
    cache = DAEVA / "cache/notproton-v1.2.0"
    zpath = cache / "NotProton.zip"
    cache.mkdir(parents=True, exist_ok=True)
    if not zpath.exists() or _sha256(zpath) != NP_ZIP_SHA256:
        subprocess.run(["curl", "-sSfL", "-o", str(zpath), NP_ZIP_URL], check=True)
    if _sha256(zpath) != NP_ZIP_SHA256:
        raise SystemExit(f"NotProton.zip sha256 mismatch")
    out = cache / "x"
    if not (out / NP_PAYLOAD).exists():
        shutil.rmtree(out, ignore_errors=True)
        # ditto keeps the bundle's symlinks and modes the way the zip carries them
        subprocess.run(["ditto", "-x", "-k", str(zpath), str(out)], check=True)
    return out / NP_PAYLOAD


def steam_running():
    return run(["pgrep", "-x", "steam_osx"])[0] == 0


def quit_steam():
    """Ask Steam to exit (keeps the login); never signs out."""
    if not steam_running():
        return False
    run(["open", "-g", "steam://exit"])
    for _ in range(120):
        if not steam_running():
            return True
        time.sleep(0.5)
    raise SystemExit("Steam did not exit; close it and retry")


def current_insert():
    with open(STEAM_APP / "Contents/Info.plist", "rb") as f:
        return plistlib.load(f).get("LSEnvironment", {}).get(INSERT_KEY)


def install_notproton(pl):
    dylib = STEAM_APP / "Contents/MacOS/notproton.dylib"
    plist = STEAM_APP / "Contents/Info.plist"
    insert = current_insert()
    if insert and insert != str(dylib):
        raise SystemExit(f"Steam.app already injects something else: {insert}")

    backup = NP_SUPPORT / "backups/Info.plist.before-notproton"
    if not backup.exists():
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(plist, backup)
        print(f"backed up Info.plist -> {backup}")

    sigs = NP_SUPPORT / "signatures/macos.arm64"
    sigs.mkdir(parents=True, exist_ok=True)
    for f in (pl / "signatures/macos.arm64").glob("*.json"):
        shutil.copy2(f, sigs / f.name)

    if not dylib.exists() or _sha256(dylib) != _sha256(pl / "notproton.dylib"):
        shutil.copy2(pl / "notproton.dylib", dylib)
    with open(plist, "rb") as f:
        info = plistlib.load(f)
    env = info.setdefault("LSEnvironment", {})
    env[INSERT_KEY] = str(dylib)
    env[CONTROLLER_KEY] = CONTROLLER_VALUE
    with open(plist, "wb") as f:
        plistlib.dump(info, f)

    for target in (dylib, STEAM_APP / "Contents/MacOS/steam_osx", STEAM_APP):
        rc, out = run(["codesign", "-f", "-s", "-", str(target)])
        if rc:
            raise SystemExit(f"codesign {target}: {out}")
    run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
         "/Support/lsregister", "-f", str(STEAM_APP)])
    # a new cdhash means old TCC approvals no longer match; NotProton resets them too
    for svc in ("Accessibility", "PostEvent", "ListenEvent"):
        run(["tccutil", "reset", svc, "com.valvesoftware.steam"])
    print(f"Steam.app now injects {current_insert()}")


def install_compat_tool():
    COMPAT_TOOL.mkdir(parents=True, exist_ok=True)
    src = REPO / "compat/daeva"
    for name in ("toolmanifest.vdf", "compatibilitytool.vdf"):
        shutil.copy2(src / name, COMPAT_TOOL / name)
    script = (src / "run").read_text().replace("@REPO@", str(REPO)).replace("@PYTHON@", sys.executable)
    (COMPAT_TOOL / "run").write_text(script)
    (COMPAT_TOOL / "run").chmod(0o755)
    print(f"compat tool installed at {COMPAT_TOOL}")


def notproton_present():
    dylib = STEAM_APP / "Contents/MacOS/notproton.dylib"
    return current_insert() == str(dylib) and dylib.exists()


def setup():
    # Steam only scans compatibilitytools.d at startup
    was_running = quit_steam()
    if notproton_present():
        print(f"NotProton already injected ({(NP_SUPPORT / 'dylib.version').read_text().strip()}), keeping it")
    else:
        install_notproton(payload())
    install_compat_tool()
    if was_running:
        run(["open", "-a", str(STEAM_APP)])
