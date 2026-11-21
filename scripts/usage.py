#!/usr/bin/env python3
"""Live resource use of the bot and everything it runs on, refreshed every 2 s.

    python3 scripts/usage.py          # memory = each process's own heap (RssAnon)
    sudo python3 scripts/usage.py     # memory = PSS: shared libraries split fairly too
    python3 scripts/usage.py --once   # one snapshot, no screen clearing

CPU % is of the whole Pi (all cores = 100 %). The memory cgroup controller is
off on Pi OS, so memory is summed per process from each group's cgroup.procs.
GPU is the whole Pi's v3d render queue (the game is nearly all of it).
Standard library only: runs with the system python3, no venv needed.
"""
import os
import subprocess
import sys
import time

CG = "/sys/fs/cgroup"
UID = os.environ.get("SUDO_UID") or os.getuid()   # under sudo: the user who ran it
APP = f"{CG}/user.slice/user-{UID}.slice/user@{UID}.service/app.slice"
GROUPS = [   # label, cgroup dir
    ("Bot (python + adb)", f"{APP}/obelisk-bot.service"),
    ("Dashboard", f"{APP}/obelisk-dashboard.service"),
    ("Waydroid (Android)", f"{CG}/lxc.payload.waydroid"),
]
GAME = "com.checkbox.minershminer"   # shown as its own line under Waydroid
DESKTOP = ("labwc",)                  # the compositor that draws the Waydroid window
GPU_STATS = "/sys/devices/platform/axi/1002000000.v3d/gpu_stats"
EVERY = 2.0
NCPU = os.cpu_count() or 1
ROOT = os.geteuid() == 0


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
    """PSS when root (fair share of shared pages). Without root, Android's
    processes can't be read for PSS, so use RssAnon: each process's own
    heap, leaving out shared libraries (full RSS counts those 80 times)."""
    if ROOT:
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
    out = []
    for p in os.listdir("/proc"):
        if p.isdigit() and read(f"/proc/{p}/comm").strip() in names:
            out.append(int(p))
    return out


def game_pids() -> list[int]:
    out = []
    for p in cg_pids(GROUPS[2][1]):
        if read(f"/proc/{p}/cmdline").split("\0")[0] == GAME:
            out.append(p)
    return out


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


def throttled() -> str:
    v = vcgen("get_throttled")
    try:
        n = int(v, 16)
    except ValueError:
        return "?"
    now = [t for b, t in ((0, "under-voltage"), (1, "freq capped"), (2, "throttled"),
                          (3, "temp limit")) if n >> b & 1]
    past = [t for b, t in ((16, "under-voltage"), (17, "freq capped"), (18, "throttled"),
                           (19, "temp limit")) if n >> b & 1]
    if not now and not past:
        return "ok"
    return ", ".join(now) + (f" (since boot: {', '.join(past)})" if past else "")


def gb(kb: float) -> str:
    return f"{kb / 1048576:.2f} GB" if kb >= 1048576 else f"{kb / 1024:.0f} MB"


def bar(pct: float, width: int = 20) -> str:
    n = max(0, min(width, round(pct / 100 * width)))
    return "█" * n + "░" * (width - n)


def snapshot():
    return {
        "t": time.monotonic(),
        "cg": {d: cg_usec(d) for _, d in GROUPS},
        "game": {p: pid_ticks(p) for p in game_pids()},
        "desk": {p: pid_ticks(p) for p in find_pids(DESKTOP)},
        "sys": sys_cpu(),
        "gpu": gpu_render(),
    }


def ticks_pct(a: dict, b: dict, dt: float) -> float:
    hz = os.sysconf("SC_CLK_TCK")
    d = sum(b[p] - a[p] for p in b if p in a)
    return d / hz / dt / NCPU * 100


def render(a, b) -> str:
    dt = b["t"] - a["t"]
    rows, tot_cpu, tot_mem = [], 0.0, 0
    for label, d in GROUPS:
        u0, u1 = a["cg"][d], b["cg"][d]
        pids = cg_pids(d)
        if u0 is None or u1 is None:
            rows.append((label, None, 0, 0))
            continue
        cpu = (u1 - u0) / 1e6 / dt / NCPU * 100
        mem = sum(mem_kb(p) for p in pids)
        tot_cpu += cpu
        tot_mem += mem
        rows.append((label, cpu, mem, len(pids)))
        if d == GROUPS[2][1] and b["game"]:
            rows.append(("  └ the game", ticks_pct(a["game"], b["game"], dt),
                         sum(mem_kb(p) for p in b["game"]), len(b["game"])))
    desk_cpu = ticks_pct(a["desk"], b["desk"], dt)
    desk_mem = sum(mem_kb(p) for p in b["desk"])

    (t0, i0), (t1, i1) = a["sys"], b["sys"]
    pi_cpu = 100 * (1 - (i1 - i0) / max(1, t1 - t0))
    mi = meminfo()
    used = mi["MemTotal"] - mi["MemAvailable"]
    gpu = None
    if a["gpu"] and b["gpu"]:
        gpu = 100 * (b["gpu"][1] - a["gpu"][1]) / max(1, b["gpu"][0] - a["gpu"][0])

    w = 64
    out = [f" Idle Obelisk bot: resource use   {time.strftime('%H:%M:%S')}   "
           f"({'PSS' if ROOT else 'own'} memory)", "─" * w,
           f" {'Part':<22}{'CPU':>8}{'Memory':>12}{'Procs':>8}", "─" * w]
    for label, cpu, mem, n in rows:
        if cpu is None:
            out.append(f" {label:<22}{'not running':>28}")
        else:
            out.append(f" {label:<22}{cpu:>7.1f}%{gb(mem):>12}{n:>8}")
    out += ["─" * w,
            f" {'Bot total':<22}{tot_cpu:>7.1f}%{gb(tot_mem):>12}",
            f" {'+ desktop (labwc)':<22}{desk_cpu:>7.1f}%{gb(desk_mem):>12}",
            "", " Whole Pi", "─" * w,
            f" CPU   {bar(pi_cpu)} {pi_cpu:5.1f}%   of {NCPU} cores",
            f" RAM   {bar(100 * used / mi['MemTotal'])} {gb(used)} / {gb(mi['MemTotal'])}"
            f"   swap {gb(mi['SwapTotal'] - mi['SwapFree'])}",
            (f" GPU   {bar(gpu)} {gpu:5.1f}%   render busy, {vcgen('measure_clock', 'v3d')[:-6] or '?'} MHz"
             if gpu is not None else " GPU   (no v3d gpu_stats)"),
            f" Temp  {vcgen('measure_temp') or '?'}    power: {throttled()}",
            f" Load  {' '.join(read('/proc/loadavg').split()[:3])}"]
    if not ROOT:
        out.append("\n Memory leaves out shared libraries; sudo adds their fair share (PSS).")
    return "\n".join(out)


def main() -> None:
    once = "--once" in sys.argv
    a = snapshot()
    time.sleep(EVERY)
    try:
        while True:
            b = snapshot()
            text = render(a, b)
            if once:
                print(text)
                return
            sys.stdout.write("\033[H\033[2J" + text + "\n\n Ctrl+C to quit\n")
            sys.stdout.flush()
            a = b
            time.sleep(EVERY)
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
