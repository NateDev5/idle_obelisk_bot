#!/bin/bash
# Set up a headless sway session (no monitor, no keyboard/mouse) for Waydroid
# on a Debian/Ubuntu VM (e.g. Proxmox), with foot as the terminal, wayvnc to
# look at the screen and optionally noVNC to look at it from a browser.
# Starts at boot without anyone logging in.
#
# Run as the user who will run Waydroid and the bot (not root; uses sudo):
#   scripts/setup_headless_sway.sh
# Options (environment variables; each run remembers them for the next, so
# e.g. `NOVNC=1 scripts/setup_headless_sway.sh` later only adds noVNC):
#   RESOLUTION=1920x1080   size of the virtual screen
#   VNC_LAN=1              wayvnc listens on the LAN (port VNC_PORT, default
#                          5900) with a username/password; 0 = localhost only
#   NOVNC=1                noVNC in the browser: https://<vm-ip>:NOVNC_PORT/
#                          (default 6080); turns on the VNC password; 0 = off
#   WAYDROID_UI=1          open Waydroid's full UI when the session starts
#                          (default; only once Waydroid is installed and
#                          initialised, so it can be set up first); 0 = off
# Safe to run again, also after a run of an older version of this script:
# it rewrites only the files listed at the end and doesn't restart sway (so
# Waydroid keeps running); it reloads sway's config and restarts wayvnc.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user (it uses sudo where needed), not as root." >&2
    exit 1
fi
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ;;
    *) echo "This script is for Debian/Ubuntu (found ${PRETTY_NAME:-unknown})." >&2; exit 1 ;;
esac

CFG="$HOME/.config"
BIN="$HOME/.local/bin"
UNITS="$CFG/systemd/user"
STATE="$CFG/sway-headless"          # remembered options, noVNC certificate
SETTINGS="$STATE/settings"
VNC_CONF="$CFG/wayvnc/config"
mkdir -p "$CFG/sway" "$CFG/wayvnc" "$BIN" "$UNITS" "$STATE"

# --- options: environment, else the last run's, else defaults ----------------
SAVED_RESOLUTION="" SAVED_VNC_LAN="" SAVED_VNC_PORT="" SAVED_NOVNC="" SAVED_NOVNC_PORT=""
SAVED_WAYDROID_UI=""
if [ -f "$SETTINGS" ]; then
    . "$SETTINGS"
else    # an older version of this script kept no settings file: read its files
    SAVED_RESOLUTION=$(sed -n 's/^output HEADLESS-1 mode --custom //p' "$CFG/sway/config" 2>/dev/null | head -n1 || true)
    SAVED_VNC_PORT=$(sed -n 's/^port=//p' "$VNC_CONF" 2>/dev/null | head -n1 || true)
    if grep -qx 'address=0.0.0.0' "$VNC_CONF" 2>/dev/null; then SAVED_VNC_LAN=1; fi
fi
RESOLUTION="${RESOLUTION:-${SAVED_RESOLUTION:-1920x1080}}"
VNC_LAN="${VNC_LAN:-${SAVED_VNC_LAN:-0}}"
VNC_PORT="${VNC_PORT:-${SAVED_VNC_PORT:-5900}}"
NOVNC="${NOVNC:-${SAVED_NOVNC:-0}}"
NOVNC_PORT="${NOVNC_PORT:-${SAVED_NOVNC_PORT:-6080}}"
WAYDROID_UI="${WAYDROID_UI:-${SAVED_WAYDROID_UI:-1}}"

die() { echo "$*" >&2; exit 1; }
[[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]] || die "RESOLUTION must look like 1920x1080 (got '$RESOLUTION')."
[[ "$VNC_LAN" =~ ^[01]$ ]] || die "VNC_LAN must be 0 or 1 (got '$VNC_LAN')."
[[ "$NOVNC" =~ ^[01]$ ]] || die "NOVNC must be 0 or 1 (got '$NOVNC')."
[[ "$WAYDROID_UI" =~ ^[01]$ ]] || die "WAYDROID_UI must be 0 or 1 (got '$WAYDROID_UI')."
[[ "$VNC_PORT" =~ ^[0-9]+$ ]] || die "VNC_PORT must be a number (got '$VNC_PORT')."
[[ "$NOVNC_PORT" =~ ^[0-9]+$ ]] || die "NOVNC_PORT must be a number (got '$NOVNC_PORT')."
[ "$VNC_PORT" != "$NOVNC_PORT" ] || die "VNC_PORT and NOVNC_PORT must differ."
# a password whenever anything but localhost can reach the screen
AUTH=0; if [ "$VNC_LAN" = 1 ] || [ "$NOVNC" = 1 ]; then AUTH=1; fi
echo "==> Options: RESOLUTION=$RESOLUTION VNC_LAN=$VNC_LAN VNC_PORT=$VNC_PORT NOVNC=$NOVNC NOVNC_PORT=$NOVNC_PORT WAYDROID_UI=$WAYDROID_UI"

# --- packages ---------------------------------------------------------------
echo "==> Installing packages"
PKGS=(sway foot wayvnc fonts-dejavu-core dbus-user-session)
[ "$AUTH" = 1 ] && PKGS+=(openssh-client)           # ssh-keygen for wayvnc's key
[ "$NOVNC" = 1 ] && PKGS+=(novnc websockify openssl)
sudo apt-get update
# no recommends: skips swayidle/swaylock (nothing should blank or lock the
# screen) and Xwayland (Waydroid doesn't need it)
sudo apt-get install -y --no-install-recommends "${PKGS[@]}"

# --- the bot's venv: headless OpenCV --------------------------------------------
# Nothing on the VM opens an OpenCV window, so the bot uses
# opencv-python-headless (requirements-vm.txt) instead of opencv-python. The
# two can't share a venv, so the full one is removed first.
REPO=$(cd "$(dirname "$0")/.." && pwd)
VENV="$REPO/venv"
if [ -x "$VENV/bin/pip" ]; then
    echo "==> Bot venv: installing requirements-vm.txt (headless OpenCV)"
    if "$VENV/bin/pip" show -q opencv-python >/dev/null 2>&1; then
        "$VENV/bin/pip" uninstall -y -q opencv-python
    fi
    "$VENV/bin/pip" install -q -r "$REPO/requirements-vm.txt"
    VENV_STATUS="$VENV uses opencv-python-headless"
else
    VENV_STATUS="no venv yet: python3 -m venv $VENV && $VENV/bin/pip install -r $REPO/requirements-vm.txt"
fi

# GPU access (Proxmox VirGL display or a passed-through GPU). Takes effect
# after a reboot; until then sway falls back to software rendering.
NEED_REBOOT=0
for g in video render; do
    if getent group "$g" >/dev/null && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
        echo "==> Adding $USER to group $g"
        sudo usermod -aG "$g" "$USER"
        NEED_REBOOT=1
    fi
done

# --- launcher: sway with the headless backend --------------------------------
cat > "$BIN/sway-headless" <<'EOF'
#!/bin/sh
# Start sway with no monitor or input devices (wlroots headless backend).
# Written by idle_obelisk_bot/scripts/setup_headless_sway.sh.
export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export XDG_CURRENT_DESKTOP=sway XDG_SESSION_DESKTOP=sway XDG_SESSION_TYPE=wayland
# Render on the GPU if this user can open a render node, else in software.
# Set WLR_RENDERER yourself (systemctl --user edit sway-headless) to override.
if [ -z "${WLR_RENDERER:-}" ]; then
    node=""
    for n in /dev/dri/renderD*; do
        if [ -r "$n" ] && [ -w "$n" ]; then node=$n; break; fi
    done
    if [ -n "$node" ]; then
        export WLR_RENDER_DRM_DEVICE="$node"
        echo "sway-headless: GPU rendering on $node"
    else
        export WLR_RENDERER=pixman
        echo "sway-headless: no usable /dev/dri/renderD*; software rendering (pixman)"
    fi
fi
exec /usr/bin/sway
EOF

# --- run by sway at startup ----------------------------------------------------
cat > "$BIN/sway-headless-session" <<'EOF'
#!/bin/sh
# Run by sway at startup (exec in ~/.config/sway/config): make sure there is a
# virtual screen, tell systemd where the Wayland socket is, then start
# sway-session.target (wayvnc, noVNC, ~/.config/autostart entries).
# Written by idle_obelisk_bot/scripts/setup_headless_sway.sh.
if ! swaymsg -t get_outputs -r | grep -q '"name"'; then
    swaymsg create_output >/dev/null
fi
# The obelisk bot and its scripts fall back to WAYLAND_DISPLAY=wayland-0, but
# sway usually takes wayland-1: point wayland-0 at it (unless something real
# already owns wayland-0).
w0="$XDG_RUNTIME_DIR/wayland-0"
if [ "${WAYLAND_DISPLAY:-wayland-0}" != wayland-0 ] && { [ -L "$w0" ] || [ ! -e "$w0" ]; }; then
    ln -sfn "$WAYLAND_DISPLAY" "$w0"
fi
systemctl --user import-environment WAYLAND_DISPLAY SWAYSOCK \
    XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment --systemd WAYLAND_DISPLAY SWAYSOCK \
        XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
fi
exec systemctl --user --no-block start sway-session.target
EOF
chmod 755 "$BIN/sway-headless" "$BIN/sway-headless-session"

# --- sway config ------------------------------------------------------------------
if [ -f "$CFG/sway/config" ] && ! grep -q 'setup_headless_sway.sh' "$CFG/sway/config"; then
    cp "$CFG/sway/config" "$CFG/sway/config.bak.$(date +%s)"
    echo "==> Backed up your existing sway config"
fi
cat > "$CFG/sway/config" <<'EOF'
# Headless sway for Waydroid. Written by idle_obelisk_bot/scripts/setup_headless_sway.sh
# (rerunning the script overwrites this file).
set $mod Mod4
set $term foot

xwayland disable
default_border pixel 2
focus_follows_mouse no

# Keys (over VNC the Super key is often taken by your own computer, so the
# Ctrl+Alt versions are there too).
bindsym $mod+Return exec $term
bindsym Ctrl+Alt+Return exec $term
bindsym $mod+Shift+q kill
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+c reload
bindsym $mod+Left focus left
bindsym $mod+Right focus right
bindsym $mod+Up focus up
bindsym $mod+Down focus down
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
floating_modifier $mod normal

include /etc/sway/config.d/*
EOF
cat >> "$CFG/sway/config" <<EOF

# The virtual screen (created by sway-headless-session if sway didn't make one).
output HEADLESS-1 mode --custom $RESOLUTION
exec $BIN/sway-headless-session
EOF

# --- systemd user units -------------------------------------------------------------
cat > "$UNITS/sway-headless.service" <<'EOF'
# Headless sway session. Written by idle_obelisk_bot/scripts/setup_headless_sway.sh.
[Unit]
Description=Headless sway (Wayland session for Waydroid, no monitor needed)
Documentation=man:sway(1)

[Service]
Type=simple
ExecStart=%h/.local/bin/sway-headless
ExecStopPost=-/usr/bin/systemctl --user unset-environment WAYLAND_DISPLAY SWAYSOCK
ExecStopPost=-/bin/sh -c '[ -L %t/wayland-0 ] && rm -f %t/wayland-0; true'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

cat > "$UNITS/sway-session.target" <<'EOF'
# Started by sway once it is up (sway-headless-session); pulls in wayvnc,
# noVNC and the XDG autostart entries in ~/.config/autostart (systemd's
# generator runs them, as a desktop would). Written by setup_headless_sway.sh.
[Unit]
Description=Headless sway session (wayvnc, noVNC, XDG autostart)
BindsTo=sway-headless.service graphical-session.target
After=sway-headless.service
Wants=graphical-session-pre.target xdg-desktop-autostart.target
After=graphical-session-pre.target
EOF

cat > "$UNITS/wayvnc.service" <<'EOF'
# VNC server for the headless sway session (settings: ~/.config/wayvnc/config).
# Written by idle_obelisk_bot/scripts/setup_headless_sway.sh.
[Unit]
Description=wayvnc (VNC for the headless sway session)
PartOf=sway-session.target
Requisite=sway-session.target
After=sway-session.target

[Service]
ExecStart=/usr/bin/wayvnc --render-cursor
Restart=on-failure
RestartSec=5

[Install]
WantedBy=sway-session.target
EOF

cat > "$UNITS/novnc.service" <<EOF
# noVNC: the screen in a browser, https://<vm-ip>:$NOVNC_PORT/ (websockify
# serves noVNC and passes it on to wayvnc on localhost:$VNC_PORT). HTTPS with a
# self-signed certificate: noVNC's login needs the browser's WebCrypto, which
# browsers only allow on https pages. Written by setup_headless_sway.sh.
[Unit]
Description=noVNC (browser view of the headless sway session)
PartOf=sway-session.target
Requisite=sway-session.target
After=wayvnc.service

[Service]
ExecStart=/usr/bin/websockify --web /usr/share/novnc --ssl-only --cert $STATE/novnc.crt --key $STATE/novnc.key 0.0.0.0:$NOVNC_PORT 127.0.0.1:$VNC_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=sway-session.target
EOF

cat > "$UNITS/waydroid-ui.service" <<'EOF'
# Opens Waydroid's full UI in the headless sway session when it starts. Skipped
# until Waydroid is installed and initialised (sudo waydroid init -s GAPPS).
# If no Waydroid session is running yet, this process runs the session, so
# stopping this unit stops Waydroid. No automatic restart: the obelisk bot's
# own scripts (restart_all.sh) stop and start the Waydroid session, and a
# restart here would fight them. Written by setup_headless_sway.sh.
[Unit]
Description=Waydroid full UI in the headless sway session
PartOf=sway-session.target
Requisite=sway-session.target
After=sway-session.target wayvnc.service
ConditionPathExists=/usr/bin/waydroid
ConditionPathExists=/var/lib/waydroid/waydroid.cfg

[Service]
Type=simple
# at boot the system's waydroid-container service may not be up yet
ExecStartPre=/bin/sh -c 'for i in $$(seq 60); do systemctl is-active --quiet waydroid-container.service && exit 0; sleep 2; done; echo "waydroid-container.service is not running"; exit 1'
ExecStart=/usr/bin/waydroid show-full-ui
TimeoutStartSec=150
Restart=no

[Install]
WantedBy=sway-session.target
EOF

# --- wayvnc config ------------------------------------------------------------------
ADDR=127.0.0.1; [ "$VNC_LAN" = 1 ] && ADDR=0.0.0.0
PASS=""
umask 077
if [ "$AUTH" = 1 ]; then
    KEY="$CFG/wayvnc/rsa_key.pem"
    [ -f "$KEY" ] || ssh-keygen -q -m pem -t rsa -b 3072 -N "" -f "$KEY"
    PASS=$(sed -n 's/^password=//p' "$VNC_CONF" 2>/dev/null | head -n1 || true)
    [ -n "$PASS" ] || PASS=$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')
    cat > "$VNC_CONF" <<EOF
address=$ADDR
port=$VNC_PORT
enable_auth=true
username=$USER
password=$PASS
rsa_private_key_file=$KEY
EOF
    if [ "$NOVNC" = 1 ]; then
        # noVNC can't do wayvnc's RSA-AES login, but it can do Apple DH (ARD),
        # which wayvnc only offers with relax_encryption. Still encrypted end to
        # end here: the browser talks https/wss to websockify, and websockify
        # reaches wayvnc on localhost only.
        echo "relax_encryption=true" >> "$VNC_CONF"
    fi
else
    cat > "$VNC_CONF" <<EOF
address=$ADDR
port=$VNC_PORT
EOF
fi

# --- noVNC certificate (self-signed; kept across runs) ------------------------------
if [ "$NOVNC" = 1 ] && { [ ! -s "$STATE/novnc.crt" ] || [ ! -s "$STATE/novnc.key" ]; }; then
    echo "==> Making a self-signed certificate for noVNC"
    SAN="DNS:$(hostname),DNS:localhost,IP:127.0.0.1"
    for ip in $(hostname -I 2>/dev/null); do SAN="$SAN,IP:$ip"; done
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=$(hostname)" \
        -addext "subjectAltName=$SAN" \
        -keyout "$STATE/novnc.key" -out "$STATE/novnc.crt" 2>/dev/null
fi
umask 022

# --- remember the options for the next run -------------------------------------------
cat > "$SETTINGS" <<EOF
# Options of the last setup_headless_sway.sh run (environment variables override).
SAVED_RESOLUTION=$RESOLUTION
SAVED_VNC_LAN=$VNC_LAN
SAVED_VNC_PORT=$VNC_PORT
SAVED_NOVNC=$NOVNC
SAVED_NOVNC_PORT=$NOVNC_PORT
SAVED_WAYDROID_UI=$WAYDROID_UI
EOF

# --- start at boot without a login ---------------------------------------------------
echo "==> Enabling lingering for $USER (user services start at boot)"
sudo loginctl enable-linger "$USER"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for _ in $(seq 20); do
    systemctl --user show-environment >/dev/null 2>&1 && break
    sleep 0.5
done
if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "Couldn't reach your systemd user manager (are you in 'sudo -i' or 'su'?)." >&2
    echo "Everything is installed; reboot, or log in as $USER over SSH and rerun this script." >&2
    exit 1
fi
systemctl --user daemon-reload
systemctl --user enable sway-headless.service wayvnc.service
if [ "$NOVNC" = 1 ]; then
    systemctl --user enable novnc.service
else
    systemctl --user disable --now novnc.service 2>/dev/null || true
fi
if [ "$WAYDROID_UI" = 1 ]; then
    systemctl --user enable waydroid-ui.service
else
    # only unhook it from the session; stopping it would close Waydroid
    systemctl --user disable waydroid-ui.service 2>/dev/null || true
fi
WAYDROID_READY=0
if [ -x /usr/bin/waydroid ] && [ -f /var/lib/waydroid/waydroid.cfg ]; then WAYDROID_READY=1; fi

SWAY_WAS_RUNNING=0
if systemctl --user is-active --quiet sway-headless.service; then
    # Already running (an earlier run): apply the changes without restarting
    # sway, which would close Waydroid.
    SWAY_WAS_RUNNING=1
    echo "==> sway is already running: reloading its config, restarting wayvnc"
    SOCK=$(systemctl --user show-environment | sed -n 's/^SWAYSOCK=//p')
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
        SWAYSOCK="$SOCK" swaymsg reload >/dev/null || echo "   (swaymsg reload failed; the new config applies at the next sway start)"
    fi
    if systemctl --user is-active --quiet sway-session.target; then
        systemctl --user restart wayvnc.service
        if [ "$NOVNC" = 1 ]; then systemctl --user restart novnc.service; fi
        # start, not restart: if Waydroid is already open this leaves it be
        if [ "$WAYDROID_UI" = 1 ] && [ "$WAYDROID_READY" = 1 ]; then
            systemctl --user --no-block start waydroid-ui.service
        fi
    else
        systemctl --user start sway-session.target
    fi
else
    systemctl --user start sway-headless.service
fi

# --- check ------------------------------------------------------------------------------
echo "==> Checking"
UNITS_TO_CHECK=(sway-headless.service wayvnc.service)
[ "$NOVNC" = 1 ] && UNITS_TO_CHECK+=(novnc.service)
for _ in $(seq 20); do
    all=1
    for u in "${UNITS_TO_CHECK[@]}"; do systemctl --user is-active --quiet "$u" || all=0; done
    [ "$all" = 1 ] && break
    sleep 0.5
done
sleep 1     # a unit that dies right after starting shows up as failed by now
ok=1
for u in "${UNITS_TO_CHECK[@]}"; do
    printf '  %-22s %s\n' "$u" "$(systemctl --user is-active "$u" || true)"
    systemctl --user is-active --quiet "$u" || ok=0
done
WD=$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p' || true)
printf '  %-22s %s\n' "Wayland socket" "${WD:-not set}"
if [ "$WAYDROID_UI" = 1 ]; then
    if [ "$WAYDROID_READY" = 1 ]; then
        printf '  %-22s %s\n' "waydroid-ui.service" \
            "$(systemctl --user is-active waydroid-ui.service || true) (Android takes a minute to boot)"
    else
        printf '  %-22s %s\n' "waydroid-ui.service" "waiting: Waydroid isn't installed/initialised yet"
    fi
fi
journalctl --user -u sway-headless -b --no-pager -o cat 2>/dev/null \
    | grep '^sway-headless:' | tail -n1 | sed 's/^/  /' || true

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
echo
if [ "$ok" = 1 ]; then echo "Headless sway is running."; else
    echo "Something didn't start; see: journalctl --user -u sway-headless -u wayvnc -u novnc -b"
fi
echo
if [ "$NOVNC" = 1 ]; then
    echo "In a browser (noVNC):"
    echo "  https://${IP:-<vm-ip>}:$NOVNC_PORT/vnc.html?resize=scale"
    echo "  The certificate is self-signed, so the browser warns once: accept it"
    echo "  (\"Advanced\" -> \"Proceed\"). It must be https; http won't connect."
    echo
fi
echo "With a VNC viewer (TigerVNC works):"
if [ "$VNC_LAN" = 1 ]; then
    echo "  address  ${IP:-<vm-ip>}:$VNC_PORT"
else
    echo "  from your computer:  ssh -L $VNC_PORT:localhost:$VNC_PORT $USER@${IP:-<vm-ip>}"
    echo "  then connect the viewer to localhost:$VNC_PORT   (VNC_LAN=1: listen on the LAN)"
fi
if [ "$AUTH" = 1 ]; then
    echo
    echo "VNC login:  username $USER   password $PASS"
    echo "  (stored in $VNC_CONF)"
fi
echo
echo "In sway: Super+Enter or Ctrl+Alt+Enter opens a foot terminal."
echo "Entries in ~/.config/autostart/ start with the session, so the bot's"
echo "systemd/waydroid-obelisk.desktop works as the README describes."
echo "Bot venv: $VENV_STATUS"
if [ "$WAYDROID_UI" = 1 ] && [ "$WAYDROID_READY" = 0 ]; then
    echo "Waydroid opens by itself once it's installed and initialised:"
    echo "  sudo waydroid init -s GAPPS"
    echo "  systemctl --user start waydroid-ui     (or reboot)"
fi
if [ "$SWAY_WAS_RUNNING" = 1 ]; then
    echo "sway kept running. A change in how it renders (GPU or software) needs"
    echo "  systemctl --user restart sway-headless   (this closes Waydroid)"
fi
if [ "$NEED_REBOOT" = 1 ]; then
    echo "Reboot once so the new video/render group lets sway use the GPU."
fi
echo
echo "Files written: ~/.local/bin/sway-headless{,-session}, ~/.config/sway/config,"
echo "  ~/.config/wayvnc/config, ~/.config/sway-headless/, ~/.config/systemd/user/"
echo "  {sway-headless.service,sway-session.target,wayvnc.service,novnc.service,"
echo "  waydroid-ui.service}"
