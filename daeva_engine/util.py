"""Shared paths, redaction and small helpers."""

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HOME = Path.home()
STEAM = HOME / "Library/Application Support/Steam"
STEAM_MACOS = STEAM / "Steam.AppBundle/Steam/Contents/MacOS"
DAEVA = HOME / "Library/Application Support/Daeva"
ENGINES = DAEVA / "engines"
SCRATCH = DAEVA / "scratch"
CAPTURES = DAEVA / "captures"
PFX_AION2 = DAEVA / "pfx-aion2"
LOGS = DAEVA / "logs"
BRIDGE = DAEVA / "bridge"
GAMEFIXES = DAEVA / "gamefixes"
SETTINGS = DAEVA / "settings.json"
# shipped inside Daeva.app next to daeva_engine/; absent in a dev checkout (falls back to downloads)
PAYLOAD = REPO / "payload"

APPID = "3393110"


def lock():
    return json.loads((REPO / "engine.lock.json").read_text())


DEFAULT_SETTINGS = {
    "metal_hud": False,      # MTL_HUD_ENABLED=1
    "msync": False,          # WINEMSYNC=1
    "cpuid_fix": True,       # aion2-wine-compat (needed past NC Guard under Rosetta)
    "loaddll": False,        # WINEDEBUG +loaddll
    "discord": True,         # Discord rich presence while the game runs
}


def settings():
    try:
        saved = json.loads(SETTINGS.read_text())
    except (OSError, ValueError):
        saved = {}
    return {k: saved.get(k, v) for k, v in DEFAULT_SETTINGS.items()}


def save_settings(**changes):
    cur = settings()
    cur.update({k: v for k, v in changes.items() if k in DEFAULT_SETTINGS})
    DAEVA.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(cur, indent=1))
    return cur


def run(cmd, **kw):
    """Run a command, return (rc, combined output)."""
    kw.setdefault("timeout", 120)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, str(e)
    return p.returncode, (p.stdout + p.stderr).strip()


def write_private(path, data):
    """Atomically write bytes/str with mode 0600 inside a 0700 dir."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if isinstance(data, str):
        data = data.encode()
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


# argv/env from Steam carry session auth: keep paths and known flags, mask the rest
_KNOWN_FLAGS = re.compile(r"^-{1,2}[A-Za-z][\w.-]*$")
_SECRETISH = re.compile(r"(?i)(token|ticket|auth|session|key|pass|sig)")


def redact_arg(a):
    if a.startswith("/") or re.match(r"^[A-Za-z]:\\", a) or a.endswith(".exe"):
        return a
    if _KNOWN_FLAGS.match(a):
        return a
    if "=" in a:
        k, _, v = a.partition("=")
        return f"{k}=<redacted:{len(v)}>"
    return f"<redacted:{len(a)}>"


def redact_env(env):
    out = {}
    for k, v in env.items():
        if _SECRETISH.search(k) or not (v.startswith("/") or v.isdigit() or v == ""):
            out[k] = f"<redacted:{len(v)}>"
        else:
            out[k] = v
    return out


_STEAMID = re.compile(r"\b7656\d{13}\b|\[U:1:\d+\]")


def redact_text(s):
    return _STEAMID.sub("<steamid>", s)
