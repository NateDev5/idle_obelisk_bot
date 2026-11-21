#!/bin/bash
# Guided setup of the obelisk bot: the README's Install steps in a text UI
# (whiptail). Each step shows whether it looks done already; tick the ones to
# run. Safe to run again: done steps are left unticked, and every step can be
# rerun on its own.
#
# On the Pi or VM that will run the bot, as that user (not root; uses sudo):
#   git clone https://github.com/YNWho-0/idle_obelisk_bot ~/idle_obelisk_bot
#   ~/idle_obelisk_bot/scripts/setup.sh
#
# Debian / Ubuntu / Raspberry Pi OS. On a VM with no desktop, the first step
# runs scripts/setup_headless_sway.sh (sway + VNC) so Waydroid has a screen.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
VENV="$REPO/venv"
BOT_HOME="$HOME/idle_obelisk_bot"          # what systemd/ and the autostart entry expect
ENVD="$HOME/.config/environment.d/obelisk.conf"
DEFAULT_SERIAL="192.168.240.112:5555"     # ADB_SERIAL in obelisk/__init__.py
PACKAGE="com.checkbox.minershminer"
TITLE="Idle Obelisk bot setup"
BOT_STOPPED=0

# --- basics ---------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the user who will run the bot (it uses sudo where needed), not as root." >&2
    exit 1
fi
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ;;
    *) echo "This script is for Debian, Ubuntu or Raspberry Pi OS (found ${PRETTY_NAME:-unknown})." >&2; exit 1 ;;
esac
if ! command -v whiptail >/dev/null 2>&1; then
    read -rp "The menu needs whiptail. Install it now with apt? [Y/n] " a
    case "$a" in [nN]*) exit 1 ;; esac
    sudo apt-get install -y whiptail || exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# an adb address saved by an earlier run
if [ -f "$ENVD" ]; then
    s=$(sed -n 's/^OBELISK_ADB_SERIAL=//p' "$ENVD" | tail -n1)
    [ -n "$s" ] && export OBELISK_ADB_SERIAL="$s"
fi

# --- UI helpers ----------------------------------------------------------------
LINES_=$(tput lines 2>/dev/null || echo 24); COLS_=$(tput cols 2>/dev/null || echo 80)
H=$(( LINES_ > 30 ? 26 : LINES_ - 2 )); W=$(( COLS_ > 84 ? 80 : COLS_ - 4 ))
msg()   { whiptail --title "$TITLE" --msgbox "$1" "$H" "$W"; }
yesno() { whiptail --title "$TITLE" --yesno "$1" "$H" "$W"; }
input() { whiptail --title "$TITLE" --inputbox "$1" 12 "$W" "$2" 3>&1 1>&2 2>&3; }
say()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m!!  %s\033[0m\n' "$*"; }
enter() { read -rp "${1:-Press Enter to continue...}" _; }

# --- detection -------------------------------------------------------------------
serial()     { echo "${OBELISK_ADB_SERIAL:-$DEFAULT_SERIAL}"; }
is_vm()      { systemd-detect-virt -q --vm 2>/dev/null; }
have_sway()  { [ -x "$HOME/.local/bin/sway-headless" ]; }
have_pkg()   { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
waydroid_ok(){ command -v waydroid >/dev/null 2>&1 && [ -f /var/lib/waydroid/waydroid.cfg ]; }
wd_field()   { waydroid status 2>/dev/null | awk -F'\t' -v k="$1" '$1 ~ "^"k {print $2}'; }
android_ip() { local ip; ip=$(wd_field "IP address"); [ "$ip" = UNKNOWN ] && ip=""; echo "$ip"; }
session_up() { [ "$(wd_field Session)" = RUNNING ]; }
adb_ok()     { command -v adb >/dev/null 2>&1 && [ "$(timeout 5 adb -s "$(serial)" get-state 2>/dev/null)" = device ]; }
ashell()     { timeout 30 adb -s "$(serial)" shell "$@"; }
venv_ok()    { [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c 'import cv2, numpy, flask' 2>/dev/null; }
user_systemd(){ systemctl --user show-environment >/dev/null 2>&1; }

# Point WAYLAND_DISPLAY at the running desktop (also when run over SSH).
find_wayland() {
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then return 0; fi
    local s
    for s in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
        case "$s" in *.lock) continue ;; esac
        if [ -S "$s" ]; then export WAYLAND_DISPLAY="${s##*/}"; return 0; fi
    done
    return 1
}

# Start the Waydroid session (in the desktop) and wait for Android's IP.
ensure_session() {
    if session_up && [ -n "$(android_ip)" ]; then return 0; fi
    waydroid_ok || { warn "Waydroid isn't installed and initialised yet (Waydroid step)."; return 1; }
    if ! session_up; then
        find_wayland || { warn "No Wayland desktop is running for $USER. Log in to the desktop (Pi) or run the headless desktop step (VM)."; return 1; }
        say "Starting the Waydroid session on $WAYLAND_DISPLAY"
        if systemctl --user cat waydroid-ui.service >/dev/null 2>&1; then
            systemctl --user start waydroid-ui.service       # from setup_headless_sway.sh
        else
            setsid waydroid show-full-ui </dev/null >/dev/null 2>&1 &
        fi
    fi
    local i
    for i in $(seq 60); do
        if session_up && [ -n "$(android_ip)" ]; then echo "   Android is up at $(android_ip)"; return 0; fi
        sleep 3
    done
    warn "The Waydroid session didn't come up within 3 min (see: waydroid log)."
    return 1
}

# The bot must not press anything while a step does.
pause_bot() {
    if systemctl --user is-active --quiet obelisk-bot 2>/dev/null; then
        say "Stopping obelisk-bot while this step runs"
        systemctl --user stop obelisk-bot && BOT_STOPPED=1
    fi
}

# --- steps: each has <id>_status (one short line) and <id>_run -----------------------
STEPS=(desktop packages waydroid play adb venv options quiet ntfy services)

desktop_label="Headless desktop (VM: sway + VNC)"
desktop_status() {
    if find_wayland; then
        if have_sway; then echo "done (headless sway)"; else echo "not needed (desktop running)"; fi
    elif have_sway; then echo "installed, not running"
    elif is_vm; then echo "needed: no desktop"
    else echo "no desktop (log in on the Pi)"; fi
}
desktop_todo() { ! find_wayland && is_vm && ! have_sway; }
desktop_run() {
    if find_wayland && ! have_sway; then
        say "A desktop is already running ($WAYLAND_DISPLAY): nothing to do."
        return 0
    fi
    local novnc=0
    if yesno "This runs scripts/setup_headless_sway.sh: a sway desktop with no monitor, started at boot, with wayvnc to see it.

Also serve noVNC, to see the screen in a browser at https://<vm-ip>:6080/ (with a password)?

(Waydroid's Play sign-in in a later step needs you to see the screen: noVNC, or a VNC viewer over an ssh tunnel.)"; then novnc=1; fi
    NOVNC=$novnc "$REPO/scripts/setup_headless_sway.sh"
}

PKGS=(adb grim python3-venv python3-pip git curl ca-certificates)
packages_label="System packages (adb, grim, venv)"
packages_status() {
    local p missing=0
    for p in "${PKGS[@]}"; do have_pkg "$p" || missing=$((missing + 1)); done
    if [ "$missing" = 0 ]; then echo "done"; else echo "$missing missing"; fi
}
packages_todo() { [ "$(packages_status)" != done ]; }
packages_run() {
    say "Installing ${PKGS[*]}"
    sudo apt-get update && sudo apt-get install -y "${PKGS[@]}" || return 1
    if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
        warn "The bot needs Python 3.11 or newer; this system has $(python3 --version 2>&1)."
        return 1
    fi
}

waydroid_label="Waydroid + Google Play image"
waydroid_status() {
    if ! command -v waydroid >/dev/null 2>&1; then echo "not installed"
    elif [ ! -f /var/lib/waydroid/waydroid.cfg ]; then echo "installed, not initialised"
    elif systemctl is-active --quiet waydroid-container 2>/dev/null; then echo "done"
    else echo "container service not running"; fi
}
waydroid_todo() { [ "$(waydroid_status)" != done ]; }
waydroid_run() {
    # Raspberry Pi 5: Android needs a 4K-page kernel (the default Pi 5 kernel uses 16K).
    local cfg=/boot/firmware/config.txt
    if [ "$(getconf PAGESIZE)" != 4096 ]; then
        warn "This kernel uses $(getconf PAGESIZE)-byte pages; Waydroid needs 4096."
        if [ -f "$cfg" ] && ! grep -q '^kernel=kernel8.img' "$cfg"; then
            if yesno "Waydroid needs a kernel with 4K pages. On a Raspberry Pi 5 that is kernel8.img.

Add 'kernel=kernel8.img' to $cfg? (Takes effect after a reboot; then run this step again.)"; then
                echo 'kernel=kernel8.img' | sudo tee -a "$cfg" >/dev/null
                say "Added. Reboot (sudo reboot), then run this setup again."
                return 1
            fi
        fi
        warn "Boot this machine with a 4K-page kernel, then run this step again."
        return 1
    fi
    if ! command -v waydroid >/dev/null 2>&1; then
        sudo apt-get update
        if ! apt-cache policy waydroid 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            yesno "Waydroid isn't in this system's package sources. Add Waydroid's own apt repository?

This downloads https://repo.waydro.id and runs it as root (the install method in Waydroid's docs)." || return 1
            local tmp; tmp=$(mktemp)
            curl -fsSL https://repo.waydro.id -o "$tmp" && sudo bash "$tmp"; local rc=$?
            rm -f "$tmp"
            [ "$rc" = 0 ] || return 1
        fi
        say "Installing Waydroid"
        sudo apt-get install -y waydroid || return 1
    fi
    if [ ! -f /var/lib/waydroid/waydroid.cfg ]; then
        say "Initialising Waydroid with the GAPPS image (downloads ~1 GB)"
        sudo waydroid init -s GAPPS || return 1
    fi
    say "Enabling waydroid-container.service"
    sudo systemctl enable --now waydroid-container.service
}

play_label="Play sign-in, install game (by hand)"
play_status() {
    if adb_ok && ashell pm path "$PACKAGE" 2>/dev/null | grep -q package:; then echo "done (game installed)"
    elif session_up && waydroid app list 2>/dev/null | grep -q "$PACKAGE"; then echo "done (game installed)"
    else echo "to do"; fi
}
play_todo() { [ "${1:-}" != "done (game installed)" ]; }
play_run() {
    ensure_session || return 1
    say "Android ID for Google's device registration"
    local id
    id=$(sudo timeout 20 waydroid shell -- sh -c 'ANDROID_RUNTIME_ROOT=/apex/com.android.runtime ANDROID_DATA=/data ANDROID_TZDATA_ROOT=/apex/com.android.tzdata ANDROID_I18N_ROOT=/apex/com.android.i18n sqlite3 /data/data/com.google.android.gsf/databases/gservices.db "select value from main where name = \"android_id\";"' </dev/null 2>/dev/null | tr -dc '0-9')
    if [ -n "$id" ]; then echo "   android_id: $id"
    else echo "   (couldn't read it; see https://docs.waydro.id/faq/google-play-certification)"; fi
    cat <<EOF

Now on the Waydroid screen$(have_sway && echo " (over VNC / noVNC)"):
  1. If Play says the device isn't Play Protect certified: register the
     android_id above at https://www.google.com/android/uncertified , wait
     a few minutes, then restart the session (waydroid session stop) and
     run this step again.
  2. Open Play Store, sign in to your Google account.
  3. Install Idle Obelisk Miner, open it once and log in to your
     Checkbox/Google account so it syncs with your phone.
EOF
    enter "Press Enter once the game is installed and logged in..."
}

adb_label="adb connection, 720x1280"
adb_status() {
    if ! adb_ok; then echo "not connected"; return; fi
    if ashell wm size 2>/dev/null | grep -q 'Override size: 720x1280'; then echo "done ($(serial))"
    else echo "resolution not set"; fi
}
adb_todo() { case "${1:-}" in done*) return 1 ;; esac; }
adb_run() {
    command -v adb >/dev/null 2>&1 || { warn "adb isn't installed (packages step)."; return 1; }
    ensure_session || return 1
    local s; s="$(android_ip):5555"
    say "Connecting adb to $s"
    adb connect "$s"
    timeout 30 adb -s "$s" wait-for-device || { warn "adb couldn't reach $s."; return 1; }
    if [ "$s" != "$DEFAULT_SERIAL" ]; then
        say "Android's address isn't the bot's default ($DEFAULT_SERIAL): saving OBELISK_ADB_SERIAL=$s"
        mkdir -p "$(dirname "$ENVD")"
        printf '# Written by idle_obelisk_bot/scripts/setup.sh: adb address for the bot units.\nOBELISK_ADB_SERIAL=%s\n' "$s" > "$ENVD"
        user_systemd && systemctl --user set-environment OBELISK_ADB_SERIAL="$s"
        echo "   in $ENVD (all user services). For commands in a shell:"
        echo "   export OBELISK_ADB_SERIAL=$s"
    elif [ -f "$ENVD" ]; then
        rm -f "$ENVD"; user_systemd && systemctl --user unset-environment OBELISK_ADB_SERIAL
    fi
    export OBELISK_ADB_SERIAL="$s"
    say "Setting Android's resolution to 720x1280"
    ashell wm size 720x1280 && ashell wm size
}

venv_label="Python venv + bot packages"
venv_status() {
    if ! venv_ok; then echo "to do"
    elif "$VENV/bin/pip" show -q opencv-python-headless >/dev/null 2>&1; then echo "done (headless OpenCV)"
    else echo "done"; fi
}
venv_todo() { ! venv_ok; }
venv_run() {
    local req=requirements.txt d1=ON d2=OFF
    if is_vm || have_sway; then d1=OFF; d2=ON; fi
    req=$(whiptail --title "$TITLE" --radiolist "Which OpenCV?" 12 "$W" 2 \
        requirements.txt "opencv-python (Pi / desktop)" $d1 \
        requirements-vm.txt "opencv-python-headless (VM, no windows)" $d2 \
        3>&1 1>&2 2>&3) || return 1
    if [ ! -x "$VENV/bin/python" ]; then
        say "Creating $VENV"
        python3 -m venv "$VENV" || return 1
    fi
    # the two OpenCV packages can't share a venv
    local other=opencv-python-headless
    [ "$req" = requirements-vm.txt ] && other=opencv-python
    if "$VENV/bin/pip" show -q "$other" >/dev/null 2>&1; then
        say "Removing $other"; "$VENV/bin/pip" uninstall -y -q "$other"
    fi
    say "Installing $req"
    "$VENV/bin/pip" install -r "$REPO/$req" || return 1
    if yesno "Run the offline tests now? (about a minute, no device needed)"; then
        (cd "$REPO" && "$VENV/bin/python" -I tests/test_offline.py | tail -n 3)
    fi
    if adb_ok; then
        say "One live capture (python -m obelisk peek)"
        (cd "$REPO" && "$VENV/bin/python" -m obelisk peek)
    fi
    return 0
}

options_label="In-game Options"
options_status() { echo "by hand + script"; }
options_todo() { services_todo; }     # first setup only
options_run() {
    venv_ok || { warn "Set up the venv first."; return 1; }
    adb_ok || { warn "Connect adb first."; return 1; }
    pause_bot
    cat <<'EOF'

The script changes 13 in-game Options (visual effects off, Lootbug gem
confirmation back on, timers in true time). Your current values are not
saved: docs/game_settings.md lists the originals.

In the game: grid menu -> Options, so the Options screen is open.
EOF
    enter "Press Enter when the Options screen is open..."
    say "Current values (--check, no presses)"
    (cd "$REPO" && "$VENV/bin/python" -I scripts/set_options.py --check)
    if yesno "Apply the bot's settings now? (scripts/set_options.py presses the checkboxes and checks each one)"; then
        (cd "$REPO" && "$VENV/bin/python" -I scripts/set_options.py) || return 1
    fi
    cat <<'EOF'

Two more by hand, in the game:
  * Cloud screen: turn off "Toggle Cloud Auto-Save" (the bot uploads itself).
  * Options: turn off "Consume Buff Timers and Items Buffs offline", so buffs
    don't run down while the game is in the background.
EOF
    enter "Press Enter when both are off..."
}

QUIET_REVOKE=(org.lineageos.etar com.checkbox.minershminer com.android.vending
    com.google.android.gms com.google.android.gsf com.google.android.googlequicksearchbox
    com.google.android.apps.messaging com.google.android.dialer com.android.deskclock
    com.stevesoltys.seedvault com.google.android.projection.gearhead com.google.android.as
    com.google.android.apps.restore)
quiet_label="Android quiet (no pop-ups)"
quiet_status() {
    adb_ok || { echo "needs adb"; return; }
    if [ "$(ashell settings get global heads_up_notifications_enabled | tr -d '\r')" = 0 ] &&
       [ "$(ashell settings get system screen_off_timeout | tr -d '\r')" = 2147483647 ]; then echo "done"
    else echo "to do (optional)"; fi
}
quiet_todo() { [ "${1:-}" = "to do (optional)" ]; }
quiet_run() {
    adb_ok || { warn "Connect adb first."; return 1; }
    yesno "Change these Android settings (docs/android_settings.md has the restore commands)?

 * heads-up notifications off, Do Not Disturb on
 * screen timeout never, stay awake always
 * notification permission revoked for Calendar, Play, Google apps, Clock,
   the game and a few others (that stops those apps once)" || return 1
    pause_bot
    say "Applying"
    ashell settings put global heads_up_notifications_enabled 0
    ashell cmd notification set_dnd on
    ashell settings put system screen_off_timeout 2147483647
    ashell settings put global stay_on_while_plugged_in 7
    local p
    for p in "${QUIET_REVOKE[@]}"; do
        ashell pm revoke "$p" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 && echo "   revoked: $p"
    done
    ashell appops set com.android.mms.service POST_NOTIFICATION ignore >/dev/null 2>&1
    return 0
}

ntfy_label="Phone alerts (ntfy)"
ntfy_topic()  { sed -n 's/^topic=//p' "$REPO/notify.conf" 2>/dev/null | head -n1; }
ntfy_status() { if [ -n "$(ntfy_topic)" ]; then echo "done"; else echo "to do (optional)"; fi; }
ntfy_todo()   { [ -z "$(ntfy_topic)" ]; }
ntfy_run() {
    local t; t=$(ntfy_topic)
    [ -n "$t" ] || t="obelisk-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
    t=$(input "Install the ntfy app (https://ntfy.sh) on your phone and subscribe to this topic. Anyone who knows it can read your alerts, so keep it long and random.

Topic:" "$t") || return 1
    [ -n "$t" ] || return 1
    ( umask 077; printf 'topic=%s\n' "$t" > "$REPO/notify.conf" )
    chmod 600 "$REPO/notify.conf"
    say "Saved notify.conf (topic $t)"
    if venv_ok; then
        say "Sending a test alert"
        (cd "$REPO" && "$VENV/bin/python" -m obelisk notify-test)
    fi
    return 0
}

UNITS=(obelisk-bot.service obelisk-dashboard.service obelisk-summary.service obelisk-summary.timer
       obelisk-health.service obelisk-health.timer obelisk-bootcheck.service obelisk-bootcheck.timer)
services_label="Services, timers, dashboard"
services_status() {
    if systemctl --user is-enabled --quiet obelisk-bot 2>/dev/null; then
        echo "done (bot $(systemctl --user is-active obelisk-bot 2>/dev/null))"
    else echo "to do"; fi
}
services_todo() { ! systemctl --user is-enabled --quiet obelisk-bot 2>/dev/null; }
services_run() {
    venv_ok || { warn "Set up the venv first."; return 1; }
    user_systemd || { warn "Can't reach your systemd user manager (log in as $USER directly, not via su/sudo)."; return 1; }
    say "Lingering for $USER (services run without a login and after logout)"
    sudo loginctl enable-linger "$USER"
    say "Linking the units in systemd/"
    local u
    for u in "${UNITS[@]}"; do
        systemctl --user link "$BOT_HOME/systemd/$u" >/dev/null 2>&1 ||
            [ "$(readlink -f "$HOME/.config/systemd/user/$u")" = "$(readlink -f "$BOT_HOME/systemd/$u")" ] ||
            warn "couldn't link $u (a copy already in ~/.config/systemd/user?)"
    done
    systemctl --user daemon-reload
    systemctl --user enable --now obelisk-bot obelisk-dashboard || return 1
    systemctl --user enable --now obelisk-summary.timer obelisk-health.timer obelisk-bootcheck.timer || return 1
    BOT_STOPPED=0
    say "Autostart entry (Waydroid + game at login)"
    mkdir -p "$HOME/.config/autostart"
    cp "$REPO/systemd/waydroid-obelisk.desktop" "$HOME/.config/autostart/"
    local i tok ip
    for i in $(seq 20); do [ -f "$REPO/dashboard.conf" ] && break; sleep 0.5; done
    tok=$(sed -n 's/^token=//p' "$REPO/dashboard.conf" 2>/dev/null | head -n1)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo
    if [ -n "$tok" ]; then
        echo "Dashboard: open this once on your phone (keep port 8765 off the internet):"
        echo "  http://${ip:-<ip>}:8765/?t=$tok"
        if ! grep -q '^url=' "$REPO/dashboard.conf"; then
            echo "url=http://${ip:-<ip>}:8765/" >> "$REPO/dashboard.conf"
            echo "  (alerts open it when tapped: url= added to dashboard.conf)"
        fi
    else
        warn "No dashboard.conf yet; see: journalctl --user -u obelisk-dashboard"
    fi
    [ -n "$(ntfy_topic)" ] || echo "No notify.conf: the bot won't send phone alerts (ntfy step)."
    echo
    systemctl --user --no-pager status obelisk-bot | head -n 4
}

# --- repo location ---------------------------------------------------------------------
check_location() {
    [ "$REPO" = "$BOT_HOME" ] && return 0
    [ "$(readlink -f "$BOT_HOME" 2>/dev/null)" = "$REPO" ] && return 0
    if [ -e "$BOT_HOME" ]; then
        msg "The systemd units and the autostart entry expect the bot in $BOT_HOME, but this copy is in $REPO and $BOT_HOME is something else.

Move or remove one of them, then run this again."
        exit 1
    fi
    yesno "The systemd units and the autostart entry expect the bot in $BOT_HOME, but it is in $REPO.

Make $BOT_HOME a link to $REPO?" || exit 1
    ln -s "$REPO" "$BOT_HOME"
}

# --- main loop --------------------------------------------------------------------------
check_location
RESULTS=""
while true; do
    items=()
    for s in "${STEPS[@]}"; do
        st=$("${s}_status")
        label="${s}_label"
        on=OFF; "${s}_todo" "$st" && on=ON
        items+=("$s" "$(printf '%-36s %s' "${!label}" "[$st]")" "$on")
    done
    intro="Ticked: steps that look undone. Space toggles, Enter runs them in order."
    [ -n "$RESULTS" ] && intro="Last run:$RESULTS"
    chosen=$(whiptail --title "$TITLE" --notags --ok-button Run --cancel-button Quit \
        --checklist "$intro" "$H" "$W" $(( H - 8 )) "${items[@]}" 3>&1 1>&2 2>&3) || break
    eval "chosen=($chosen)"
    [ "${#chosen[@]}" -gt 0 ] || continue
    RESULTS=""
    for s in "${chosen[@]}"; do
        clear
        label="${s}_label"
        printf '\033[1m### %s\033[0m\n' "${!label}"
        if "${s}_run"; then r=ok; else r=FAILED; fi
        RESULTS="$RESULTS $s:$r"
        echo
        if [ "$r" = FAILED ]; then
            warn "This step failed (output above)."
            read -rp "Enter: carry on with the next step, q: back to the menu " a
            [ "$a" = q ] && break
        else
            enter "Done. Press Enter to continue..."
        fi
    done
done
clear
if [ "$BOT_STOPPED" = 1 ]; then
    echo "Starting obelisk-bot again (this setup stopped it)."
    systemctl --user start obelisk-bot
fi
echo "Setup closed. Rerun anytime: $REPO/scripts/setup.sh"
