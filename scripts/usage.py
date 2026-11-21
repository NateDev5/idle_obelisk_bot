#!/usr/bin/env python3
"""Live resource use of the bot and everything it runs on, refreshed every 2 s.

    python3 scripts/usage.py          # memory = each process's own heap (RssAnon)
    sudo python3 scripts/usage.py     # memory = PSS: shared libraries split fairly too
    python3 scripts/usage.py --once   # one snapshot, no screen clearing

The same numbers are on the dashboard's Resources card. The measuring is in
obelisk/usage.py (standard library only: the system python3 is enough).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from obelisk import usage  # noqa: E402

EVERY = 2.0


def main() -> None:
    once = "--once" in sys.argv
    a = usage.snapshot()
    time.sleep(EVERY)
    try:
        while True:
            b = usage.snapshot()
            out = usage.text(usage.measure(a, b))
            if once:
                print(out)
                return
            sys.stdout.write("\033[H\033[2J" + out + "\n\n Ctrl+C to quit\n")
            sys.stdout.flush()
            a = b
            time.sleep(EVERY)
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
