"""Daily check of the fan wiki's Codes page: a phone alert when a new reward code appears.

  python -m obelisk codes              # check now (obelisk-codes.timer runs it daily)
  python -m obelisk codes --dry-run    # print what the page lists; no alert, nothing saved

Reads the page's wikitext through the MediaWiki API (one small request a day)
and takes the rows of its "Reward Codes" table ({{Code|NAME}} || reward ||
requires || cloud save). Codes already seen are kept in logs/state.json
("wiki_codes_known"); the first run only records what's there. A code only
counts as seen once its alert went out, so a failed alert is retried the next
day. If the page loads but no codes can be read from it (the wiki changed its
layout), one alert says so instead of staying silent forever.

It never touches the game: redeeming stays a manual step (Menu > Options > Enter Code).
"""

from __future__ import annotations

import json
import logging
import re
import urllib.parse
import urllib.request

from . import notify

log = logging.getLogger("obelisk.codes")

API = "https://shminer.miraheze.org/w/api.php"
PAGE = "Codes"
PAGE_URL = "https://shminer.miraheze.org/wiki/Codes"
USER_AGENT = "idle-obelisk-bot-codes-check/1.0 (daily, one request)"
STATE_KEY = "wiki_codes_known"


def fetch_wikitext() -> str:
    q = urllib.parse.urlencode({"action": "parse", "page": PAGE, "prop": "wikitext",
                                "format": "json", "formatversion": 2})
    req = urllib.request.Request(f"{API}?{q}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["parse"]["wikitext"]


def clean(cell: str) -> str:
    """Wikitext cell -> plain text ("{{Gems|250}}; 2x [[File:..]] Skill Points" ->
    "250 gems; 2x Skill Points")."""
    s = re.sub(r"<!--.*?-->", "", cell, flags=re.S)
    s = re.sub(r"<ref[^>/]*/>|<ref[^>]*>.*?</ref>", "", s, flags=re.S)
    s = re.sub(r"\{\{CollapsedDescription\|.*?\}\}", "", s, flags=re.S)
    s = re.sub(r"\{\{Gems\|([^}|]+)\}\}", r"\1 gems", s)
    s = re.sub(r"\{\{NA\}\}", "", s)
    s = re.sub(r"\[\[File:[^\]]*\]\]", "", s)
    s = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"\{\{[^{}]*\}\}", "", s)                # any other template
    s = re.sub(r"<[^>]+>|'''?", "", s)
    return re.sub(r"\s+", " ", s).strip(" ;")


def parse(wikitext: str) -> dict[str, dict]:
    """{CODE: {"reward": str, "requires": str}} from the Reward Codes table."""
    m = re.search(r"==\s*Reward Codes\s*==(.*?)(?:\n==[^=]|\Z)", wikitext, flags=re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        if not line.startswith("|") or "{{Code|" not in line:
            continue
        cells = [c for c in line[1:].split("||")]
        code = re.search(r"\{\{Code\|([^}|]+)", cells[0])
        if not code:
            continue
        out[code.group(1).strip()] = {
            "reward": clean(cells[1]) if len(cells) > 1 else "",
            "requires": clean(cells[2]) if len(cells) > 2 else "",
        }
    return out


def message(new: dict[str, dict]) -> str:
    lines = []
    for code, info in new.items():
        line = f"{code}: {info['reward'] or 'reward not listed'}"
        if info["requires"]:
            line += f" (needs {info['requires']})"
        lines.append(line)
    return "\n".join(lines) + "\nRedeem: Menu > Options > Enter Code."


def check(state=None, fetch=fetch_wikitext, alert=notify.alert, dry_run: bool = False) -> list[str]:
    """Returns the new codes (alerted, or would be with dry_run)."""
    if state is None:
        from .jobs import State
        state = State()
    try:
        codes = parse(fetch())
    except Exception as e:                      # offline, wiki down: try again tomorrow
        log.warning("codes: could not read the wiki page: %s", e)
        return []
    if dry_run:
        for code, info in codes.items():
            print(f"{code:32} {info['reward']}" + (f"  (needs {info['requires']})"
                                                     if info["requires"] else ""))
    if not codes:
        log.warning("codes: the page loaded but no codes could be read from it")
        if not dry_run:
            alert("codes_unreadable", "Obelisk bot: codes check broken",
                  "The wiki's Codes page loaded but no codes could be read from it; "
                  "its layout probably changed.", tags="warning", state=state, click=PAGE_URL)
        return []
    known = state.get(STATE_KEY)
    if known is None:                           # first run: just remember what's there
        if not dry_run:
            state.set(STATE_KEY, sorted(codes))
        log.info("codes: first check, %d codes %s, no alert", len(codes),
                 "listed (dry run: not saved)" if dry_run else "recorded")
        return []
    new = {c: i for c, i in codes.items() if c not in known}
    if not new:
        log.info("codes: no new codes (%d listed)", len(codes))
        return []
    log.info("codes: new on the wiki: %s", ", ".join(new))
    if dry_run:
        return list(new)
    title = f"New Obelisk code{'s' if len(new) > 1 else ''}: {', '.join(new)}"
    if alert("codes:" + ",".join(sorted(new)), title, message(new), tags="gift", state=state,
             force=True, click=PAGE_URL):
        state.set(STATE_KEY, sorted(set(known) | set(new)))   # removed codes stay known
    return list(new)
