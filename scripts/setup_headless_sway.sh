#!/bin/bash
# Set up a headless sway session (no monitor, no keyboard/mouse) for Waydroid
# on a Debian/Ubuntu VM (e.g. Proxmox), with foot as the terminal and wayvnc
# to look at the screen. Starts at boot without anyone logging in.
#
# Run as the user who will run Waydroid and the bot (not root; uses sudo):
#   scripts/setup_headless_sway.sh
# Options (environment variables):
#   RESOLUTION=1920x1080   size of the virtual screen
#   VNC_LAN=1              wayvnc listens on the LAN with a username/password
#                          (default: localhost only; connect via an SSH tunnel)
#   VNC_PORT=5900
# Safe to run again: it rewrites only the files listed at the end.
set -euo pipefail

RESOLUTION="${RESOLUTION:-1920x1080}"
VNC_LAN="${VNC_LAN:-0}"
VNC_PORT="${VNC_PORT:-5900}"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user (it uses sudo where needed), not as root." >&2
    exit 1
fi
if ! [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "RESOLUTION must look like 1920x1080 (got '$RESOLUTION')." >&2
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
NEED_REBOOT=0
mkdir -p "$CFG/sway" "$CFG/wayvnc" "$BIN" "$UNITS"

# --- packages ---------------------------------------------------------------
echo "==> Installing sway, foot, wayvnc"
PKGS=(sway foot wayvnc fonts-dejavu-core dbus-user-session)
[ "$VNC_LAN" = 1 ] && PKGS+=(openssh-client)      # ssh-keygen for the VNC key
sudo apt-get update
# no recommends: skips swayidle/swaylock (nothing should blank or lock the
# screen) and Xwayland (Waydroid doesn't need it)
sudo apt-get install -y --no-install-recommends "${PKGS[@]}"

# GPU access (Proxmox VirGL display or a passed-through GPU). Takes effect
# after a reboot; until then sway falls back to software rendering.
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
# sway-session.target (wayvnc + ~/.config/autostart entries).
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
# Started by sway once it is up (sway-headless-session); pulls in wayvnc and
# the XDG autostart entries in ~/.config/autostart (systemd's generator runs
# them, as a desktop would). Written by setup_headless_sway.sh.
[Unit]
Description=Headless sway session (wayvnc, XDG autostart)
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

# --- wayvnc config ------------------------------------------------------------------
VNC_CONF="$CFG/wayvnc/config"
if [ "$VNC_LAN" = 1 ]; then
    KEY="$CFG/wayvnc/rsa_key.pem"
    [ -f "$KEY" ] || ssh-keygen -q -m pem -t rsa -b 3072 -N "" -f "$KEY"
    chmod 600 "$KEY"
    PASS=$(sed -n 's/^password=//p' "$VNC_CONF" 2>/dev/null || true)
    [ -n "$PASS" ] || PASS=$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')
    umask 077
    cat > "$VNC_CONF" <<EOF
address=0.0.0.0
port=$VNC_PORT
enable_auth=true
username=$USER
password=$PASS
rsa_private_key_file=$KEY
EOF
    umask 022
else
    cat > "$VNC_CONF" <<EOF
address=127.0.0.1
port=$VNC_PORT
EOF
fi
chmod 600 "$VNC_CONF"

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
    echo "Everything is installed; reboot, or log in as $USER over SSH and run:" >&2
    echo "  systemctl --user daemon-reload && systemctl --user enable --now sway-headless wayvnc" >&2
    exit 1
fi
systemctl --user daemon-reload
systemctl --user enable sway-headless.service wayvnc.service
if systemctl --user is-active --quiet sway-headless.service; then
    echo "==> sway-headless was already running; not restarting it (that would close"
    echo "    Waydroid). Apply changes with: systemctl --user restart sway-headless"
else
    systemctl --user start sway-headless.service
fi

# --- check ------------------------------------------------------------------------------
echo "==> Checking"
ok=1
for _ in $(seq 20); do
    systemctl --user is-active --quiet wayvnc.service && break
    sleep 0.5
done
for u in sway-headless.service wayvnc.service; do
    printf '  %-22s %s\n' "$u" "$(systemctl --user is-active "$u" || true)"
    systemctl --user is-active --quiet "$u" || ok=0
done
WD=$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')
printf '  %-22s %s\n' "Wayland socket" "${WD:-not set}"
journalctl --user -u sway-headless -b --no-pager -o cat 2>/dev/null \
    | grep -m1 '^sway-headless:' | sed 's/^/  /' || true

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
if [ "$ok" = 1 ]; then echo "Headless sway is running."; else
    echo "Something didn't start; see: journalctl --user -u sway-headless -u wayvnc -b"
fi
echo
echo "Look at the screen with a VNC viewer (TigerVNC works):"
if [ "$VNC_LAN" = 1 ]; then
    echo "  address  ${IP:-<vm-ip>}:$VNC_PORT"
    echo "  username $USER"
    echo "  password $PASS     (stored in $VNC_CONF)"
else
    echo "  from your computer:  ssh -L $VNC_PORT:localhost:$VNC_PORT $USER@${IP:-<vm-ip>}"
    echo "  then connect the viewer to localhost:$VNC_PORT"
    echo "  (or rerun with VNC_LAN=1 to listen on the LAN with a password)"
fi
echo "In sway: Super+Enter or Ctrl+Alt+Enter opens a foot terminal."
echo
echo "Entries in ~/.config/autostart/ start with the session, so the bot's"
echo "systemd/waydroid-obelisk.desktop works as the README describes."
[ "$NEED_REBOOT" = 1 ] && echo "Reboot once so the new video/render group lets sway use the GPU."
echo
echo "Files written: ~/.local/bin/sway-headless{,-session}, ~/.config/sway/config,"
echo "  ~/.config/wayvnc/config, ~/.config/systemd/user/{sway-headless.service,"
echo "  sway-session.target,wayvnc.service}"
