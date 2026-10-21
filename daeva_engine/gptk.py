"""Import D3DMetal from a user-supplied Game Porting Toolkit DMG into a copy of an engine.

Layout follows frankea/Whisky PR #164: PE forwarders are copied over the builtins,
lib/external gets D3DMetal.framework + libd3dshared.dylib, and the x86_64-unix .so
entries are symlinks to ../../external/libd3dshared.dylib (D3DMetal locates itself
through them; dereferenced copies fail with "Failed to dlopen D3DMetal").
GPTK 4 adds d3d12core, which d3d12.dll needs; nvapi64 / nvngx are left out as in #164.
"""

import hashlib
import plistlib
import shutil
import subprocess
from pathlib import Path

from .engine import engine_dir, wine_root
from .util import run

MODULES = ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi"]
EVAL_GLOB = "Evaluation environment for Windows games*.dmg"


def _attach(dmg):
    out = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", str(dmg)],
                         capture_output=True, check=True).stdout
    for e in plistlib.loads(out)["system-entities"]:
        if e.get("mount-point"):
            return Path(e["mount-point"])
    raise SystemExit(f"{dmg}: nothing mounted")


def _detach(mnt):
    run(["hdiutil", "detach", str(mnt)])


def _sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def find_redist(dmg):
    """Mount the GPTK DMG (and its nested evaluation image); return (redist/lib, mounts)."""
    mounts = [_attach(dmg)]
    lib = mounts[0] / "redist/lib"
    if not lib.is_dir():
        inner = sorted(mounts[0].glob(EVAL_GLOB))
        if not inner:
            raise SystemExit("no evaluation environment image in the GPTK DMG")
        mounts.append(_attach(inner[-1]))
        lib = mounts[-1] / "redist/lib"
    if not (lib / "external/D3DMetal.framework").is_dir():
        raise SystemExit(f"{lib}: no D3DMetal.framework")
    return lib, mounts


def verify_apple(path):
    rc, out = run(["codesign", "--verify", "--strict", str(path)])
    if rc:
        raise SystemExit(f"{path}: signature check failed: {out}")
    rc, info = run(["codesign", "-dv", "--verbose=4", str(path)])
    if "Authority=Apple Root CA" not in info or "Authority=Software Signing" not in info:
        raise SystemExit(f"{path}: not signed by Apple")


def manifest(lib):
    files = {}
    for m in MODULES:
        files[f"wine/x86_64-windows/{m}.dll"] = _sha(lib / f"wine/x86_64-windows/{m}.dll")
    files["external/libd3dshared.dylib"] = _sha(lib / "external/libd3dshared.dylib")
    files["external/D3DMetal.framework/D3DMetal"] = _sha(lib / "external/D3DMetal.framework/D3DMetal")
    return files


def deploy(src_engine, lib):
    """Clone src_engine to '<name>+gptk' and lay D3DMetal into the clone."""
    dst = src_engine.with_name(src_engine.name + "+gptk")
    tmp = dst.with_name(dst.name + ".part")
    shutil.rmtree(tmp, ignore_errors=True)
    # APFS clone: cheap, and the pristine engine is never touched
    subprocess.run(["cp", "-cR", str(src_engine), str(tmp)], check=True)
    wlib = wine_root(tmp) / "lib"

    ext = wlib / "external"
    ext.mkdir(exist_ok=True)
    for name in ("D3DMetal.framework", "libd3dshared.dylib"):
        target = ext / name
        if target.exists():
            shutil.rmtree(target) if target.is_dir() else target.unlink()
        # ditto keeps the framework's symlinks and signature intact
        subprocess.run(["ditto", str(lib / "external" / name), str(target)], check=True)

    for m in MODULES:
        shutil.copy2(lib / f"wine/x86_64-windows/{m}.dll", wlib / f"wine/x86_64-windows/{m}.dll")
        so = wlib / f"wine/x86_64-unix/{m}.so"
        if so.exists() or so.is_symlink():
            so.unlink()
        so.symlink_to("../../external/libd3dshared.dylib")

    verify_apple(ext / "D3DMetal.framework")
    verify_apple(ext / "libd3dshared.dylib")
    if dst.exists():
        shutil.rmtree(dst)
    tmp.rename(dst)
    return dst


def import_gptk(dmg, pin):
    lib, mounts = find_redist(dmg)
    try:
        verify_apple(lib / "external/D3DMetal.framework")
        verify_apple(lib / "external/libd3dshared.dylib")
        files = manifest(lib)
        dst = deploy(engine_dir(pin), lib)
    finally:
        for m in reversed(mounts):
            _detach(m)
    return dst, files
