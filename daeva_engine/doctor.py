"""Host and setup checks. Each check returns (ok, summary, fix)."""

import platform
import re
from pathlib import Path

from . import vdf
from .util import APPID, STEAM, STEAM_MACOS, lock, run, redact_text


def _ver(s):
    return tuple(int(x) for x in re.findall(r"\d+", s)[:3])


def check_macos():
    rc, ver = run(["sw_vers", "-productVersion"])
    _, build = run(["sw_vers", "-buildVersion"])
    pin = lock()["engine"]
    ok = rc == 0 and _ver(ver) >= _ver(pin["min_macos"]) and _ver(ver)[0] < 28
    why = f"macOS {ver} ({build}) -> engine {pin['tag']}"
    if _ver(ver)[0] >= 28:
        why += "; macOS 28 drops most of Rosetta, D3DMetal is x86_64-only"
    return ok, why, f"needs macOS >= {pin['min_macos']} and < 28"


def check_cpu():
    _, brand = run(["sysctl", "-n", "machdep.cpu.brand_string"])
    ok = platform.machine() == "arm64" and brand.startswith("Apple")
    return ok, f"{platform.machine()}, {brand}", "Apple Silicon required"


def check_rosetta():
    rc, _ = run(["arch", "-x86_64", "/usr/bin/true"])
    return rc == 0, "x86_64 translation works" if rc == 0 else "Rosetta missing", \
        "softwareupdate --install-rosetta --agree-to-license"


def steam_state():
    log = STEAM / "logs/connection_log.txt"
    try:
        lines = log.read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        m = re.search(r"\] \[(Logged On|Logged Off|Logging On|Logging Off|Connecting|Connected),", line)
        if m:
            return m.group(1), line[1:20]
    return None


def check_steam():
    if not (STEAM_MACOS / "steam_osx").exists() and not Path("/Applications/Steam.app").exists():
        return False, "native Steam not installed", "install Steam for macOS"
    rc, _ = run(["pgrep", "-f", "Steam.AppBundle/Steam/Contents/MacOS/steam_osx"])
    if rc != 0:
        return False, "Steam installed but not running", "open -a Steam and sign in"
    st = steam_state()
    if not st or st[0] != "Logged On":
        return False, f"Steam running, last state {st[0] if st else 'unknown'}", "sign in to Steam"
    return True, f"running, Logged On since {st[1]}", ""


def library_folders():
    lf = STEAM / "steamapps/libraryfolders.vdf"
    out = [STEAM]
    try:
        for v in vdf.load(lf).get("libraryfolders", {}).values():
            if isinstance(v, dict) and v.get("path"):
                p = Path(v["path"])
                if p not in out:
                    out.append(p)
    except OSError:
        pass
    return out


def find_game():
    """Return (install_dir, manifest dict) for AION 2, or None."""
    for lib in library_folders():
        acf = lib / f"steamapps/appmanifest_{APPID}.acf"
        if acf.exists():
            m = vdf.load(acf).get("AppState", {})
            return lib / "steamapps/common" / m.get("installdir", ""), m
    return None


def check_game():
    g = find_game()
    if not g:
        return False, "AION 2 (3393110) not installed in any library", \
            "enable Steam Play (NotProton) then install AION 2 in Steam"
    d, m = g
    flags = int(m.get("StateFlags", "0"))
    ok = flags == 4 and d.is_dir()
    return ok, f"{d} buildid={m.get('buildid')} StateFlags={flags}", \
        "" if ok else "finish/repair the install in Steam (StateFlags must be 4)"


def check_tool(name, cmd, fix, required=True):
    rc, out = run(cmd)
    first = out.splitlines()[0] if out else ""
    return rc == 0 or not required, f"{first}" if rc == 0 else f"{name} missing", fix


CHECKS = [
    ("macOS", check_macos),
    ("cpu", check_cpu),
    ("rosetta", check_rosetta),
    ("steam", check_steam),
    ("aion2", check_game),
    ("xcode", lambda: check_tool("xcode", ["xcode-select", "-p"], "xcode-select --install")),
    ("mingw-w64", lambda: check_tool("mingw-w64", ["x86_64-w64-mingw32-gcc", "--version"],
                                     "brew install mingw-w64")),
]


def main(extra=()):
    bad = 0
    for name, fn in list(CHECKS) + list(extra):
        try:
            ok, summary, fix = fn()
        except Exception as e:  # a broken check is a red check
            ok, summary, fix = False, f"check crashed: {e!r}", ""
        mark = "\033[32m✓\033[0m" if ok else "\033[31m✗\033[0m"
        print(f"{mark} {name:<16} {redact_text(summary)}")
        if not ok:
            bad += 1
            if fix:
                print(f"  {'':<16} fix: {fix}")
    print("all green" if not bad else f"{bad} check(s) failing")
    return 1 if bad else 0
