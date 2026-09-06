"""DPI-aware physical input for the UI suite's native save-loader stage."""
import argparse
from pathlib import Path
import sys
import subprocess
import time
import faulthandler
sys.path.insert(0, str(Path(__file__).resolve().parent))
from live_ui.desktop import Desktop
from live_ui.runner import write_json, read_json
from live_ui.menu import scroll_step


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--x", type=float)
    parser.add_argument("--y", type=float)
    parser.add_argument("--key", choices=["escape"])
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--menu-status")
    parser.add_argument("--save-name")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--minidump", action="store_true")
    args = parser.parse_args()
    if not args.capture_only and not args.menu_status and not args.key and (args.x is None or args.y is None or not (0 <= args.x <= 1 and 0 <= args.y <= 1)):
        parser.error("normalized click coordinate required")
    if not args.worker:
        try:
            child = subprocess.run([sys.executable, __file__, *sys.argv[1:], "--worker"], timeout=20,
                                   creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True, text=True)
            write_json(args.receipt + ".worker.json", {"exitCode": child.returncode,
                       "stdout": child.stdout, "stderr": child.stderr})
            return child.returncode
        except subprocess.TimeoutExpired as exc:
            stderr = exc.stderr.decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else exc.stderr
            write_json(args.receipt + ".worker.json", {"exitCode": 2, "error": "20-second input watchdog", "stderr": stderr})
            print("UI input helper exceeded 20 seconds; stopped before the next launcher action.", file=sys.stderr)
            return 2
    faulthandler.dump_traceback_later(8)
    desktop = Desktop({"target": args.pid})
    try:
        if args.capture_only:
            dump = None
            if args.minidump:
                from live_ui.hang_dump import capture
                dump = capture(args.pid, Path(args.receipt).with_suffix(".dmp"))
            receipt = desktop.screenshot("target", Path(args.receipt).with_suffix(".png"))
            if dump: receipt["minidump"] = dump
            write_json(args.receipt, receipt)
            return 0
        if args.menu_status:
            inputs = []
            for _ in range(12):
                step = scroll_step(read_json(args.menu_status), args.save_name)
                if step is None:
                    write_json(args.receipt, {"processId": args.pid, "saveRowVisible": True, "inputs": inputs})
                    return 0
                desktop.input("target", step)
                inputs.append(step)
                time.sleep(.6)
            raise RuntimeError("save row remained clipped after bounded native scrolling")
        step = {"action": "key", "key": args.key} if args.key else {"action": "click", "point": [args.x, args.y]}
        if not args.key:
            desktop.screenshot("target", Path(args.receipt).with_suffix(".before.png"))
        desktop.input("target", step)
        write_json(args.receipt, {"processId": args.pid, "foregroundVerified": True,
                                 "dpiAware": True, "input": step,
                                 "screenPoint": getattr(desktop, "last_input_point", None)})
    except Exception:
        try:
            desktop.screenshot("target", Path(args.receipt).with_suffix(".failed.png"))
        except Exception:
            pass  # Preserve the original input/identity error.
        raise
    finally:
        desktop.close()
        faulthandler.cancel_dump_traceback_later()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
