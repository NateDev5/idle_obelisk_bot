"""Resource use of the bot and everything it runs on: CPU, memory, GPU, temperature.

Used by the dashboard's Resources card and by scripts/usage.py (terminal view).
Standard library only, so scripts/usage.py runs with the system python3.

CPU % is of the whole Pi (all cores = 100 %), from each group's cgroup cpu.stat.
The memory cgroup controller is off on Pi OS, so memory is summed per process
from each group's cgroup.procs: PSS when root (shared pages split fairly),
otherwise RssAnon (each process's own heap; Android's other processes can't be
read for PSS, and full RSS would count the shared libraries 80 times over).
GPU is the whole Pi's v3d render queue: the game is nearly all of it.

History: the dashboard service runs record_forever() in a thread, appending
one line a minute to logs/usage.csv (kept HISTORY_DAYS), whether or not anyone
has the page open; history() reads it back for the card's graph.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path

from . import PACKAGE

CG = "/sys/fs/cgroup"
UID = os.environ.get("SUDO_UID") or os.getuid()      # under sudo: the user who ran it
APP = f"{CG}/user.slice/user-{UID}.slice/user@{UID}.service/app.slice"
WAYDROID = f"{CG}/lxc.payload.waydroid"
GROUPS = [   # label, cgroup dir
    ("Bot (python + adb)", f"{APP}/obelisk-bot.service"),
    ("Dashboard", f"{APP}/obelisk-dashboard.service"),
    ("Waydroid (Android)", WAYDROID),
]
DESKTOP = ("labwc",)                  # the compositor that draws the Waydroid window
GPU_STATS = "/sys/devices/platform/axi/1002000000.v3d/gpu_stats"
THERMAL = "/sys/class/thermal/thermal_zone0/temp"
NCPU = os.cpu_count() or 1
HZ = os.sysconf("SC_CLK_TCK")
PSS = os.geteuid() == 0
HISTORY = Path(__file__).resolve().parent.parent / "logs" / "usage.csv"
HISTORY_EVERY = 60                    # seconds between history lines
HISTORY_DAYS = 8
HISTORY_COLS = ("ts", "cpu", "ram", "bot_cpu", "bot_mem_kb", "gpu", "temp")   # cpu/ram/gpu in %


def read(path: str) -> str:
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def cg_usec(d: str) -> int | None:
    for line in read(f"{d}/cpu.stat").splitlines():
        if line.startswith("usage_usec "):
            return int(line.split()[1])
    return None


def cg_pids(d: str) -> list[int]:
    return [int(p) for p in read(f"{d}/cgroup.procs").split()]


def mem_kb(pid: int) -> int:
    if PSS:
        for line in read(f"/proc/{pid}/smaps_rollup").splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    for line in read(f"/proc/{pid}/status").splitlines():
        if line.startswith("RssAnon:"):
            return int(line.split()[1])
    return 0


def pid_ticks(pid: int) -> int:
    s = read(f"/proc/{pid}/stat")
    if not s:
        return 0
    f = s.rsplit(")", 1)[1].split()
    return int(f[11]) + int(f[12])          # utime + stime


def find_pids(names: tuple[str, ...]) -> list[int]:
    return [int(p) for p in os.listdir("/proc")
            if p.isdigit() and read(f"/proc/{p}/comm").strip() in names]


def game_pids() -> list[int]:
    return [p for p in cg_pids(WAYDROID)
            if read(f"/proc/{p}/cmdline").split("\0")[0] == PACKAGE]


def sys_cpu() -> tuple[int, int]:
    f = [int(x) for x in read("/proc/stat").splitlines()[0].split()[1:]]
    return sum(f), f[3] + f[4]               # total, idle + iowait


def gpu_render() -> tuple[int, int] | None:
    for line in read(GPU_STATS).splitlines():
        f = line.split()
        if f and f[0] == "render":
            return int(f[1]), int(f[3])      # timestamp ns, busy ns
    return None


def meminfo() -> dict:
    out = {}
    for line in read("/proc/meminfo").splitlines():
        k, v = line.split(":", 1)
        out[k] = int(v.split()[0])
    return out


def vcgen(*args: str) -> str:
    try:
        return subprocess.run(["vcgencmd", *args], capture_output=True, text=True,
                              timeout=2).stdout.strip().split("=", 1)[-1]
    except (OSError, subprocess.TimeoutExpired):
        return ""


def throttled() -> tuple[str, bool]:
    """(text, ok). ok is False only for a problem happening right now."""
    try:
        n = int(vcgen("get_throttled"), 16)
    except ValueError:
        return "?", True
    names = ("under-voltage", "freq capped", "throttled", "temp limit")
    now = [t for b, t in enumerate(names) if n >> b & 1]
    past = [t for b, t in enumerate(names) if n >> (16 + b) & 1]
    if not now and not past:
        return "ok", True
    return (", ".join(now) or "ok now") + (f" (since boot: {', '.join(past)})" if past else ""), not now


def snapshot() -> dict:
    return {
        "t": time.monotonic(),
        "cg": {d: cg_usec(d) for _, d in GROUPS},
        "game": {p: pid_ticks(p) for p in game_pids()},
        "desk": {p: pid_ticks(p) for p in find_pids(DESKTOP)},
        "sys": sys_cpu(),
        "gpu": gpu_render(),
    }


def ticks_pct(a: dict, b: dict, dt: float) -> float:
    return sum(b[p] - a[p] for p in b if p in a) / HZ / dt / NCPU * 100


def measure(a: dict, b: dict) -> dict:
    """Use between two snapshots, as plain numbers (memory in kB)."""
    dt = max(b["t"] - a["t"], 1e-3)
    rows, tot_cpu, tot_mem = [], 0.0, 0
    for label, d in GROUPS:
        u0, u1 = a["cg"][d], b["cg"][d]
        if u0 is None or u1 is None:
            rows.append({"label": label, "cpu": None, "mem": 0, "procs": 0, "sub": False})
            continue
        pids = cg_pids(d)
        cpu = (u1 - u0) / 1e6 / dt / NCPU * 100
        mem = sum(mem_kb(p) for p in pids)
        tot_cpu += cpu
        tot_mem += mem
        rows.append({"label": label, "cpu": cpu, "mem": mem, "procs": len(pids), "sub": False})
        if d == WAYDROID and b["game"]:
            rows.append({"label": "the game", "cpu": ticks_pct(a["game"], b["game"], dt),
                         "mem": sum(mem_kb(p) for p in b["game"]), "procs": len(b["game"]),
                         "sub": True})
    (t0, i0), (t1, i1) = a["sys"], b["sys"]
    mi = meminfo()
    gpu = None
    if a["gpu"] and b["gpu"]:
        gpu = 100 * (b["gpu"][1] - a["gpu"][1]) / max(1, b["gpu"][0] - a["gpu"][0])
    temp = read(THERMAL).strip()
    power, power_ok = throttled()
    return {
        "rows": rows,
        "total": {"cpu": tot_cpu, "mem": tot_mem},
        "desktop": {"cpu": ticks_pct(a["desk"], b["desk"], dt),
                    "mem": sum(mem_kb(p) for p in b["desk"])},
        "cpu": 100 * (1 - (i1 - i0) / max(1, t1 - t0)),
        "ncpu": NCPU,
        "ram_used": mi["MemTotal"] - mi["MemAvailable"], "ram_total": mi["MemTotal"],
        "swap_used": mi["SwapTotal"] - mi["SwapFree"],
        "gpu": gpu,
        "gpu_mhz": (vcgen("measure_clock", "v3d") or "0000000")[:-6] or "?",
        "temp": int(temp) / 1000 if temp.isdigit() else None,
        "power": power, "power_ok": power_ok,
        "load": " ".join(read("/proc/loadavg").split()[:3]),
        "pss": PSS,
        "window": dt,
    }


class Sampler:
    """For the dashboard: each call measures since the previous one (its 5 s
    refresh is the window). A baseline older than MAX_AGE, or none, is taken
    fresh with a short wait, so the first view isn't an hour-long average."""
    MIN_AGE, MAX_AGE, FIRST_WAIT = 1.5, 30.0, 1.0

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.last: dict | None = None
        self.result: dict | None = None

    def get(self) -> dict:
        with self.lock:
            now = time.monotonic()
            if self.result and now - self.last["t"] < self.MIN_AGE:
                return self.result                  # several tabs refreshing at once
            if not self.last or now - self.last["t"] > self.MAX_AGE:
                self.last = snapshot()
                time.sleep(self.FIRST_WAIT)
            b = snapshot()
            self.result, self.last = measure(self.last, b), b
            return self.result


# ---------------------------------------------------------------- history

def history_line(m: dict, ts: float) -> str:
    vals = (int(ts), m["cpu"], 100 * m["ram_used"] / m["ram_total"], m["total"]["cpu"],
            m["total"]["mem"], m["gpu"], m["temp"])
    return ",".join("" if v is None else f"{v:.1f}" if isinstance(v, float) else str(v)
                    for v in vals) + "\n"


def trim_history(path: Path | None = None, now: float | None = None) -> None:
    path = path or HISTORY
    cut = (now or time.time()) - HISTORY_DAYS * 86400
    try:
        lines = path.read_text().splitlines(keepends=True)
    except OSError:
        return
    keep = [ln for ln in lines if ln[:1].isdigit() and float(ln.split(",", 1)[0]) >= cut]
    if len(keep) != len(lines):
        tmp = path.with_suffix(".tmp")
        tmp.write_text("".join(keep))
        tmp.replace(path)


def record_forever(path: Path | None = None) -> None:
    """One history line a minute, each the average over that minute."""
    path = path or HISTORY
    path.parent.mkdir(parents=True, exist_ok=True)
    trim_history(path)
    a, n = snapshot(), 0
    while True:
        time.sleep(HISTORY_EVERY)
        try:
            b = snapshot()
            with open(path, "a") as f:
                f.write(history_line(measure(a, b), time.time()))
            a, n = b, n + 1
            if n % 360 == 0:                      # every 6 h
                trim_history(path)
        except Exception:                         # never let the thread die
            a = snapshot()


def start_history() -> None:
    threading.Thread(target=record_forever, name="usage-history", daemon=True).start()


_cache: dict = {}


def history(hours: float, path: Path | None = None, now: float | None = None) -> list[tuple]:
    """[(ts, cpu %, ram %)] for the last `hours`, oldest first."""
    path = path or HISTORY
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return []
    key = (str(path), mtime)
    if _cache.get("key") != key:
        rows = []
        for ln in path.read_text().splitlines():
            f = ln.split(",")
            try:
                rows.append((float(f[0]), float(f[1]), float(f[2])))
            except (ValueError, IndexError):
                continue
        _cache.update(key=key, rows=rows)
    cut = (now or time.time()) - hours * 3600
    return [r for r in _cache["rows"] if r[0] >= cut]


# ---------------------------------------------------------------- terminal view

def fmt_mem(kb: float) -> str:
    return f"{kb / 1048576:.2f} GB" if kb >= 1048576 else f"{kb / 1024:.0f} MB"


def bar(pct: float, width: int = 20) -> str:
    n = max(0, min(width, round(pct / 100 * width)))
    return "█" * n + "░" * (width - n)


def text(m: dict) -> str:
    w = 64
    out = [f" Idle Obelisk bot: resource use   {time.strftime('%H:%M:%S')}   "
           f"({'PSS' if m['pss'] else 'own'} memory)", "─" * w,
           f" {'Part':<22}{'CPU':>8}{'Memory':>12}{'Procs':>8}", "─" * w]
    for r in m["rows"]:
        label = ("  └ " if r["sub"] else "") + r["label"]
        if r["cpu"] is None:
            out.append(f" {label:<22}{'not running':>28}")
        else:
            out.append(f" {label:<22}{r['cpu']:>7.1f}%{fmt_mem(r['mem']):>12}{r['procs']:>8}")
    t, dk = m["total"], m["desktop"]
    gpu = m["gpu"]
    out += ["─" * w,
            f" {'Bot total':<22}{t['cpu']:>7.1f}%{fmt_mem(t['mem']):>12}",
            f" {'+ desktop (labwc)':<22}{dk['cpu']:>7.1f}%{fmt_mem(dk['mem']):>12}",
            "", " Whole Pi", "─" * w,
            f" CPU   {bar(m['cpu'])} {m['cpu']:5.1f}%   of {m['ncpu']} cores",
            f" RAM   {bar(100 * m['ram_used'] / m['ram_total'])} {fmt_mem(m['ram_used'])}"
            f" / {fmt_mem(m['ram_total'])}   swap {fmt_mem(m['swap_used'])}",
            (f" GPU   {bar(gpu)} {gpu:5.1f}%   render busy, {m['gpu_mhz']} MHz"
             if gpu is not None else " GPU   (no v3d gpu_stats)"),
            f" Temp  {m['temp']:.1f} °C    power: {m['power']}" if m["temp"] is not None
            else f" Temp  ?    power: {m['power']}",
            f" Load  {m['load']}"]
    if not m["pss"]:
        out.append("\n Memory leaves out shared libraries; sudo adds their fair share (PSS).")
    return "\n".join(out)
