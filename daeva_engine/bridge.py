"""Steam bridge: stage Valve's Windows client DLLs + steam.exe into a prefix, build the env.

lsteamclient itself is the engine's builtin (winecx ships it, our ntdll patch routes
steamclient64 into it), so only the files steam_api expects on disk are staged.
"""

import hashlib
import os
import shutil
import urllib.request
import zipfile
from pathlib import Path

from .engine import CACHE, wine_env, wine_root
from .util import BRIDGE, PAYLOAD, STEAM_MACOS, lock

# older setups got these from the NotProton app; still accepted as a source
NP_BRIDGE = Path.home() / "Library/Application Support/notproton/bridge"
FILES = ("steamclient.dll", "steamclient64.dll", "tier0_s64.dll", "vstdlib_s64.dll", "steam.exe")
STEAM_DIR = "drive_c/Program Files (x86)/Steam"
STEAM_EXE = r"C:\Program Files (x86)\Steam\steam.exe"


def _sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def bridge_hashes(src=BRIDGE):
    return {name: _sha(src / name) for name in FILES}


def missing():
    """Bridge files absent or not matching the pins."""
    want = lock()["bridge_files"]
    return [n for n in FILES if not (BRIDGE / n).exists() or _sha(BRIDGE / n) != want[n]]


def _valve_package(name, sha, bases, log):
    dst = CACHE / "valve" / name
    if dst.exists() and _sha(dst) == sha:
        return dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    for base in bases:
        log(f"downloading {name} from {base.split('/')[2]}")
        tmp = dst.with_suffix(".part")
        try:
            with urllib.request.urlopen(f"{base}/{name}", timeout=60) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f)
        except OSError as e:
            log(f"  failed: {e}")
            continue
        if _sha(tmp) == sha:
            os.replace(tmp, dst)
            return dst
        log("  sha256 mismatch, trying next mirror")
        tmp.unlink(missing_ok=True)
    raise SystemExit(f"could not fetch Valve package {name}")


def install(log=print):
    """Fill BRIDGE: Valve DLLs from Valve's CDN (pinned), steam.exe from the app payload."""
    pins, valve = lock()["bridge_files"], lock()["valve"]
    BRIDGE.mkdir(parents=True, exist_ok=True)
    zips = {}
    for name, (pkg, inner) in valve["files"].items():
        if (BRIDGE / name).exists() and _sha(BRIDGE / name) == pins[name]:
            continue
        if pkg not in zips:
            zips[pkg] = _valve_package(*valve["packages"][pkg], valve["bases"], log)
        with zipfile.ZipFile(zips[pkg]) as z, z.open(inner) as src, open(BRIDGE / name, "wb") as out:
            shutil.copyfileobj(src, out)
        if _sha(BRIDGE / name) != pins[name]:
            raise SystemExit(f"{name}: sha256 mismatch after extract")
        log(f"verified {name}")
    exe = BRIDGE / "steam.exe"
    if not exe.exists() or _sha(exe) != pins["steam.exe"]:
        for src in (PAYLOAD / "steam.exe", NP_BRIDGE / "steam.exe"):
            if src.exists() and _sha(src) == pins["steam.exe"]:
                shutil.copy2(src, exe)
                log("verified steam.exe")
                break
        else:
            raise SystemExit("steam.exe (pinned build) not found in the app payload")
    return missing()


def stage(prefix):
    dst = Path(prefix) / STEAM_DIR
    dst.mkdir(parents=True, exist_ok=True)
    src_dir = BRIDGE if not missing() else NP_BRIDGE
    for name in FILES:
        src = src_dir / name
        if not (dst / name).exists() or _sha(dst / name) != _sha(src):
            shutil.copy2(src, dst / name)
    return dst


def env(engine, prefix, appid, **extra):
    wroot = wine_root(engine)
    steam_dir = Path(prefix) / STEAM_DIR
    e = wine_env(prefix, wroot)
    e.pop("DYLD_INSERT_LIBRARIES", None)
    e.update({
        "STEAM_DYLD_INSERT_LIBRARIES": "",
        "SteamAppId": str(appid), "SteamGameId": str(appid), "STEAM_COMPAT_APP_ID": str(appid),
        "STEAM_COMPAT_DATA_PATH": str(Path(prefix).parent),
        "STEAM_COMPAT_CLIENT_INSTALL_PATH": str(STEAM_MACOS),
        "WINEDLLOVERRIDES": "steamclient=n;steamclient64=n;lsteamclient=b",
        "WINEDLLPATH": os.pathsep.join([str(steam_dir), str(wroot / "lib/wine/x86_64-windows"),
                                        str(wroot / "lib/wine/x86_64-unix")]),
    })
    e.update(extra)
    return e
