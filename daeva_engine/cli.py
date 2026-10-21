"""daeva-engine: run AION 2 from native macOS Steam on winecx-gptk + D3DMetal."""

import argparse
import json

from . import doctor

COMMANDS = ["doctor", "setup", "capture", "launch", "play", "recover", "logs"]


def _emit(**obj):
    print(json.dumps(obj), flush=True)


def gui_api(args):
    """Machine-readable commands for Daeva.app: one JSON object per line on stdout."""
    from . import launch, setup
    from .util import redact_text, save_settings, settings

    if args.cmd == "status":
        _emit(steps=setup.status(), running=launch.running(), settings=settings(),
              art=setup.artwork())
        return 0
    if args.cmd == "settings":
        changes = {}
        for kv in args.set or []:
            k, _, v = kv.partition("=")
            changes[k] = v.lower() in ("1", "true", "yes", "on")
        _emit(settings=save_settings(**changes) if changes else settings())
        return 0
    if args.cmd == "step":
        try:
            setup.run_step(args.id, lambda m: _emit(progress=redact_text(str(m))), dmg=args.dmg)
        except SystemExit as e:
            _emit(error=redact_text(str(e)))
            return 1
        except Exception as e:  # surface, don't traceback into the GUI
            _emit(error=redact_text(f"{type(e).__name__}: {e}"))
            return 1
        _emit(done=args.id)
        return 0
    return 2


def main(argv=None):
    ap = argparse.ArgumentParser(prog="daeva-engine", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    parsers = {c: sub.add_parser(c) for c in COMMANDS}
    parsers["play"].add_argument("--loaddll", action="store_true", help="log +loaddll for this launch")
    sr = sub.add_parser("steam-run", help="internal: called by the daeva compat tool")
    sr.add_argument("verb")
    sr.add_argument("argv", nargs=argparse.REMAINDER)
    sub.add_parser("status", help="JSON: setup steps, running state, settings, artwork")
    st = sub.add_parser("step", help="JSON lines: run one setup step")
    st.add_argument("id")
    st.add_argument("--dmg", help="Game Porting Toolkit .dmg (gptk step)")
    se = sub.add_parser("settings", help="JSON: show or change launch settings")
    se.add_argument("--set", action="append", metavar="KEY=on|off")
    args = ap.parse_args(argv)

    if args.cmd in ("status", "step", "settings"):
        return gui_api(args)

    if args.cmd in ("steam-run", "capture", "launch", "play", "recover", "logs"):
        from . import launch
        if args.cmd == "steam-run":
            rest = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            return launch.steam_run(args.verb, rest)
        if args.cmd == "play":
            return launch.play(args.loaddll)
        return {"capture": launch.capture, "launch": launch.launch_from_capture,
                "recover": launch.recover, "logs": launch.logs}[args.cmd]()

    if args.cmd == "doctor":
        return doctor.main()
    from . import setup
    for s in setup.status():
        if s["ok"] or not s["can_run"] or s["id"] == "gptk":
            continue
        print(f"== {s['title']}")
        setup.run_step(s["id"], print)
    return doctor.main()
