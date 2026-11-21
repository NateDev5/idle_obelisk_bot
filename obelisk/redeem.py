"""Enter every reward code listed on the wiki, to make sure none was missed.

Requested from the dashboard ("Enter all wiki codes"): state
"codes_redeem_requested" is True (the wiki's current list) or a list of codes
(used for live tests with harmless ones, e.g. ["ALEX", "ZZZ"]). The scheduler
runs it like any job, from the mining screen: in a normal session after the
cloud check, so what it claims is uploaded at the end of that session; in
keep-open mode at once, uploaded when the mode ends.

Path: grid menu -> Options -> Codes, an in-game keyboard (letters only) with a
Submit button. For each code: clear the input, press its letters, check the
input box grew by about that many letters, Submit, and wait for the game's
answer, which replaces the input line in yellow (after a server check for real
codes, during which Submit shows a spinner; easter eggs answer at once).
"> Invalid entry <" is recognised; any other answer (e.g. already used, or a
reward) is kept as a picture of that line for the dashboard, with a full
screenshot next to it. A code answered "Invalid entry" is typed once more,
slowly, checking every letter registered, in case a key press was missed.

Results (newest run only) are in state "codes_redeem_last" and logs/codes/.
"""

from __future__ import annotations

import logging
import shutil
import time
from pathlib import Path

import cv2

from . import screens
from .jobs import JobAborted, State, ensure_mining, press_anchor, wait_for
from .screens import A, CODE_CLEAR, CODE_ECHO, CODE_EMPTY_W, CODE_KEYS, GRID_MENU, MINING, OPTIONS

log = logging.getLogger("obelisk.redeem")

REQUEST = "codes_redeem_requested"
LAST = "codes_redeem_last"
SHOTS = Path(__file__).resolve().parent.parent / "logs" / "codes"
PER_LETTER = (7, 15)             # px the input box grows per letter (measured 10-13)


class RedeemCodesJob:
    name = "codes"
    long = True                   # minutes, not seconds: not counted in the session limit
    ANSWER_WAIT = 20.0            # s for the game's answer after Submit
    KEY_WAIT = 2.0                # s for one letter to show (slow retry)

    def __init__(self, state: "State | None" = None, fetch=None):
        self.state = state if state is not None else State()
        self.fetch = fetch        # () -> [codes]; default: the wiki, else the saved list

    def due(self, now: float, frame) -> bool:
        return bool(self.state.get(REQUEST))

    # ---- the list ----------------------------------------------------------

    def code_list(self, request) -> tuple[list[str], str]:
        if isinstance(request, list):
            return [str(c) for c in request], "given list"
        if self.fetch is not None:
            return list(self.fetch()), "wiki"
        from . import codes
        try:
            return list(codes.parse(codes.fetch_wikitext())), "wiki"
        except Exception as e:                       # offline: the daily check's list
            known = self.state.get(codes.STATE_KEY) or []
            log.warning("codes: wiki not reachable (%s); using the %d saved codes", e, len(known))
            return list(known), "saved list (wiki not reachable)"

    # ---- run -----------------------------------------------------------------

    def run(self, dev) -> str:
        request = self.state.get(REQUEST)
        self.state.set(REQUEST, None)                # one go per press, even if it fails
        self.state.set("session_now", None)          # the dashboard asked for one to run this
        codes, source = self.code_list(request)
        if not codes:
            self._save([], source, done=True, error="no codes to enter")
            return "no codes"
        shutil.rmtree(SHOTS, ignore_errors=True)
        SHOTS.mkdir(parents=True, exist_ok=True)
        results: list[dict] = []
        error = None
        self._save(results, source, done=False)
        log.info("codes: entering %d codes (%s)", len(codes), source)
        try:
            self.open_keyboard(dev)
            for code in codes:
                results.append(self.enter(dev, code))
                log.info("codes: %s -> %s", code, results[-1]["result"])
                self._save(results, source, done=False)
        except JobAborted as e:
            error = str(e)
            raise
        finally:
            self._save(results, source, done=True, error=error)
            self.close(dev)
        counts = {}
        for r in results:
            counts[r["result"]] = counts.get(r["result"], 0) + 1
        return "entered " + ", ".join(f"{n} {k}" for k, n in counts.items())

    def _save(self, results, source, done: bool, error=None) -> None:
        self.state.set(LAST, {"at": time.time(), "source": source, "done": done,
                              "error": error, "results": results})

    # ---- screens -----------------------------------------------------------

    def open_keyboard(self, dev) -> None:
        frame = ensure_mining(dev, "codes: ")
        press_anchor(dev, "grid_button", frame)
        frame = wait_for(dev, lambda f: screens.identify(f) == GRID_MENU, timeout=5)
        if frame is None:
            raise JobAborted("codes: grid menu did not open", dev.capture())
        press_anchor(dev, "grid_options_button", frame)
        frame = wait_for(dev, lambda f: screens.identify(f) == OPTIONS, timeout=6)
        if frame is None:
            raise JobAborted("codes: Options did not open", dev.capture())
        if screens.codes_keyboard(frame) is not None:   # still open from last time
            return
        label = A.get("options_codes_label").find(frame)
        dev.press(label.center[0], label.center[1] + screens.CODES_ICON_OFFSET)
        frame = wait_for(dev, lambda f: screens.codes_keyboard(f) is not None
                         and A.get("codes_submit").find(f) is not None, timeout=6)
        if frame is None:
            raise JobAborted("codes: the code keyboard did not open", dev.capture())

    @staticmethod
    def close(dev) -> None:
        """Back to the mining screen; the menus' X closes Options and the keyboard."""
        frame = wait_for(dev, lambda f: screens.identify(f) in (OPTIONS, GRID_MENU, MINING), timeout=5)
        if frame is None or screens.identify(frame) == MINING:
            return
        x = A.get("store_close").find(frame)
        if x is not None:
            dev.press(*x.center)
            if wait_for(dev, lambda f: screens.identify(f) == MINING, timeout=6) is None:
                log.warning("codes: not back on the mining screen after closing")

    # ---- one code ----------------------------------------------------------

    def enter(self, dev, code: str) -> dict:
        code = code.strip().upper()
        if not code or any(c not in CODE_KEYS for c in code):
            return {"code": code, "result": "skipped", "note": "not only letters A-Z"}
        for attempt in (1, 2):
            slow = attempt == 2
            frame = self.clear(dev)
            frame = self.type(dev, code, frame, slow)
            box = screens.code_box(frame)
            lo, hi = (CODE_EMPTY_W + PER_LETTER[0] * len(code), CODE_EMPTY_W + PER_LETTER[1] * len(code))
            if box is None or not lo <= box[2] <= hi or screens.code_text_colour(frame) != "white":
                if slow:
                    return {"code": code, "result": "typing failed",
                            "note": f"input box {box[2] if box else '-'} px, expected {lo}-{hi}"}
                log.info("codes: %s didn't type cleanly (box %s); typing it again slowly", code, box)
                continue
            submit = A.get("codes_submit").find(frame)
            if submit is None:
                raise JobAborted("codes: Submit button not found", frame)
            dev.press(*submit.center)
            frame = self.wait_answer(dev, code)
            if frame is None:
                return {"code": code, "result": "no answer"}
            invalid = A.get("codes_invalid").find(frame) is not None
            if invalid and not slow:
                log.info("codes: %s -> Invalid entry; typing it again slowly to be sure", code)
                continue
            result = {"code": code, "result": "invalid" if invalid else "answered",
                      "answer": self.keep(code, frame)}
            if slow:
                result["note"] = "typed twice"
            return result
        return {"code": code, "result": "typing failed"}

    def clear(self, dev):
        frame = dev.capture()
        shift = screens.codes_keyboard(frame)
        if shift is None:
            raise JobAborted("codes: keyboard not shown", frame)
        dev.press(CODE_CLEAR[0] + shift[0], CODE_CLEAR[1] + shift[1])
        frame = wait_for(dev, lambda f: (b := screens.code_box(f)) is not None
                         and abs(b[2] - CODE_EMPTY_W) <= 4
                         and screens.code_box(f, CODE_ECHO) is None, timeout=3)
        if frame is None:
            raise JobAborted("codes: the input didn't clear", dev.capture())
        return frame

    def type(self, dev, code: str, frame, slow: bool):
        shift = screens.codes_keyboard(frame)
        if shift is None:
            raise JobAborted("codes: keyboard not shown", frame)
        width = screens.code_box(frame)[2]
        for c in code:
            x, y = CODE_KEYS[c]
            dev.press(x + shift[0], y + shift[1])
            if not slow:
                continue
            for _ in range(2):                         # re-press once if it didn't register
                grown = wait_for(dev, lambda f: (b := screens.code_box(f)) is not None
                                 and b[2] > width, timeout=self.KEY_WAIT, interval=0.2)
                if grown is not None:
                    width = screens.code_box(grown)[2]
                    break
                dev.press(x + shift[0], y + shift[1])
        if not slow:
            dev.sleep(0.4)                              # let the last letter draw
        frame = wait_for(dev, lambda f: screens.code_box(f) is not None, timeout=2)
        return frame if frame is not None else dev.capture()

    def wait_answer(self, dev, code: str):
        """The frame with the game's answer, None if it never came. Aborts if the
        keyboard went away (a popup over it: the next codes can't be typed)."""
        def answered(f):
            if screens.codes_keyboard(f) is None:
                raise JobAborted(f"codes: the keyboard went away after submitting {code}", f)
            return (A.get("codes_submit").find(f) is not None
                    and screens.code_box(f, CODE_ECHO) is not None
                    and screens.code_text_colour(f) == "yellow")
        frame = wait_for(dev, answered, timeout=self.ANSWER_WAIT, interval=0.4)
        if frame is not None:
            dev.sleep(0.6)                              # toasts, if any, come with the answer
            frame = dev.capture()
            if not answered(frame):
                frame = wait_for(dev, answered, timeout=3, interval=0.4)
        if frame is None:
            cv2.imwrite(str(SHOTS / f"{code}_noanswer.jpg"), dev.capture())
        return frame

    @staticmethod
    def keep(code: str, frame) -> str:
        """Save the answer line (dashboard) and the whole screen; returns the line's file name."""
        x, y, w, h = screens.code_box(frame)
        name = f"{code}.png"
        cv2.imwrite(str(SHOTS / name), frame[y - 2:y + h + 2, x - 2:x + w + 2])
        cv2.imwrite(str(SHOTS / f"{code}.jpg"), frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
        return name
