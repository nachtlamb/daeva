"""Engine download, verification, extraction and smoke tests."""

import hashlib
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

from .util import DAEVA, ENGINES, SCRATCH, lock, run

CACHE = DAEVA / "cache"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def engine_dir(pin=None):
    pin = pin or lock()["engine"]
    return ENGINES / f"winecx-gptk-{pin['tag']}"


def wine_root(edir):
    """The Wine tree inside an extracted Whisky Libraries tarball."""
    return edir / "Libraries/Wine"


def fetch(pin):
    CACHE.mkdir(parents=True, exist_ok=True)
    dst = CACHE / f"{pin['tag']}-Libraries.tar.gz"
    if not dst.exists() or sha256(dst) != pin["sha256"]:
        tmp = dst.with_suffix(".part")
        print(f"downloading {pin['url']}")
        with urllib.request.urlopen(pin["url"]) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f)
        os.replace(tmp, dst)
    got = sha256(dst)
    if got != pin["sha256"]:
        raise SystemExit(f"sha256 mismatch for {dst}: {got} != {pin['sha256']}")
    print(f"verified {dst.name} sha256={got}")
    return dst


def extract(pin, tarball):
    dst = engine_dir(pin)
    if (wine_root(dst) / "bin/wineserver").exists():
        print(f"engine already extracted at {dst}")
        return dst
    tmp = dst.with_name(dst.name + ".part")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    with tarfile.open(tarball) as t:
        # tar member names come from an untrusted archive: refuse escapes
        t.extractall(tmp, filter="tar")
    os.replace(tmp, dst)
    print(f"extracted to {dst}")
    return dst


def dequarantine(path):
    cmd = ["xattr", "-dr", "com.apple.quarantine", str(path)]
    print("+ " + " ".join(f"'{c}'" if " " in c else c for c in cmd))
    subprocess.run(cmd, check=False)


def wine_env(prefix, wroot, **extra):
    env = {k: v for k, v in os.environ.items() if k not in ("DYLD_INSERT_LIBRARIES",)}
    env.update(WINEPREFIX=str(prefix), WINESERVER=str(wroot / "bin/wineserver"),
               WINEDEBUG="err+all,fixme-all", WINEMSYNC="0")
    env.update(extra)
    return env


def wine(wroot, prefix, *args, timeout=300, **extra):
    cmd = ["arch", "-x86_64", str(wroot / "bin/wine"), *args]
    return run(cmd, env=wine_env(prefix, wroot, **extra), timeout=timeout)


def wineserver_kill(wroot, prefix):
    run(["arch", "-x86_64", str(wroot / "bin/wineserver"), "-k"],
        env=wine_env(prefix, wroot), timeout=30)


def smoke(edir, prefix=None):
    wroot = wine_root(edir)
    prefix = prefix or SCRATCH / "pfx-smoke"
    prefix.parent.mkdir(parents=True, exist_ok=True)
    results = []

    rc, out = wine(wroot, prefix, "--version", timeout=60)
    results.append(("wine --version", rc == 0, out.splitlines()[-1] if out else ""))

    rc, out = wine(wroot, prefix, "wineboot", "--init", timeout=600, WINEDLLOVERRIDES="mscoree,mshtml=")
    wineserver_kill(wroot, prefix)
    ntdll32 = prefix / "drive_c/windows/syswow64/ntdll.dll"
    ok = (prefix / "system.reg").exists() and ntdll32.exists() and ntdll32.stat().st_size > 0
    results.append(("wineboot --init", ok,
                    f"system.reg={'yes' if (prefix / 'system.reg').exists() else 'no'} "
                    f"syswow64/ntdll.dll={ntdll32.stat().st_size if ntdll32.exists() else 0}B rc={rc}"))
    return results
