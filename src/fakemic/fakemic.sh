#!/usr/bin/env bash
# fakemic — manage a fake virtual microphone (silent or white noise) and make it
# the default capture device, so browsers list it first / pre-select it.
#
#   fakemic silent   ensure a SILENT fake mic, set as default
#   fakemic white    ensure a WHITE-NOISE fake mic, set as default
#   fakemic clear    remove the fake mic, restore normal audio
#   fakemic status   show current state and available microphones
#   fakemic          show this help
#
# Architecture:
#   * Carrier = a PipeWire null-sink named "fake_mic". Its monitor source
#     "fake_mic.monitor" is the fake microphone (what browsers capture).
#     In silent mode nothing feeds the sink -> the monitor is digital silence.
#   * White noise = a `sox` generator streamed into fake_mic via the PulseAudio
#     API (PULSE_SINK=fake_mic), run by a per-user systemd unit so it survives
#     reboot. The monitor then carries the noise.
#   * The carrier is made default capture with `pactl set-default-source`; the
#     previous default is saved and restored by `fakemic clear`.
#   * Reboot persistence: a PipeWire config drop-in recreates the carrier on
#     startup; the systemd unit recreates the noise feeder (only in white mode).
#
# Safety: the feeder targets fake_mic by name and is always stopped BEFORE the
# carrier is removed, so noise is never redirected to the real output (e.g.
# headphones). The feeder also refuses to run unless fake_mic exists.

set -uo pipefail

# --- colors (only when writing to a terminal, unless NO_COLOR is set) -------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C0=$'\033[0m';  CB=$'\033[1m';  CD=$'\033[2m'
  CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CC=$'\033[36m'; CM=$'\033[35m'
  export FAKEMIC_COLOR=1
else
  C0=''; CB=''; CD=''; CR=''; CG=''; CY=''; CC=''; CM=''
  export FAKEMIC_COLOR=0
fi
# color a "good/bad" state word: $1 = 1 (good) -> green $2, else yellow $3
state_word() { if [ "$1" = "1" ]; then printf '%s%s%s' "$CG" "$2" "$C0"; else printf '%s%s%s' "$CY" "$3" "$C0"; fi; }

FAKEMIC_NAME="fake_mic"
FAKEMIC_MONITOR="fake_mic.monitor"
FAKEMIC_DESC="Fake Microphone"
NOISE_GAIN="${FAKEMIC_NOISE_GAIN:--20}"     # dBFS of the white noise
NOISE_SECS="${FAKEMIC_NOISE_SECS:-86400}"   # one 24h continuous stream per sox run

CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF_FILE="$CONF_DIR/99-fakemic.conf"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fakemic"
MODE_FILE="$STATE_DIR/mode"
PREV_DEFAULT_FILE="$STATE_DIR/prev_default_source"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/fakemic-noise.service"
UNIT_NAME="fakemic-noise.service"

die() { echo "fakemic: $*" >&2; exit 1; }

# --- session / deps ---------------------------------------------------------
detect_session() {
  if pactl get-default-sink >/dev/null 2>&1; then return 0; fi
  local uid; uid="$(id -u)"
  if [ -S "/run/user/$uid/pulse/native" ]; then
    export XDG_RUNTIME_DIR="/run/user/$uid" PULSE_SERVER="unix:/run/user/$uid/pulse/native"
    pactl get-default-sink >/dev/null 2>&1 && return 0
  fi
  die "cannot connect to PulseAudio/PipeWire. Run fakemic from your graphical user session."
}

# Map a missing command -> package name on the detected distro ($1=cmd, $2=id).
_dep_pkg() {
  case "$1" in
    pactl)
      case "$2" in
        arch|manjaro|endeavouros|garuda|cachyos|artix) echo libpulse ;;
        opensuse*|suse|sles)                           echo pulseaudio-utils ;;
        *)                                             echo pulseaudio-utils ;;
      esac ;;
    sox) echo sox ;;
    *)   echo "$1" ;;
  esac
}

# Detect the distro's package installer + package names for the missing cmds.
# Prints "<installer> <pkg...>" or empty if the distro is unknown.
# $1 = os-release ID, $2.. = missing commands.
_dep_install_line() {
  local id="$1"; shift
  local inst="" pkgs=() c
  case "$id" in
    debian|ubuntu|linuxmint|pop|kali)
      inst="apt-get install -y" ;;
    arch|manjaro|endeavouros|garuda|cachyos|artix)
      inst="pacman -S --noconfirm --needed" ;;
    fedora|rhel|rocky|almalinux|centos|amzn|nobara)
      inst="dnf install -y" ;;
    opensuse*|suse|sles)
      inst="zypper install -y" ;;
    *) return 1 ;;
  esac
  for c in "$@"; do pkgs+=( "$(_dep_pkg "$c" "$id")" ); done
  printf '%s %s' "$inst" "${pkgs[*]}"
}

check_deps() {
  local missing=()
  command -v pactl >/dev/null 2>&1 || missing+=(pactl)
  command -v sox   >/dev/null 2>&1 || missing+=(sox)
  if [ "${#missing[@]}" -eq 0 ]; then
    command -v systemctl >/dev/null 2>&1 || \
      echo "fakemic: warning: systemctl not found; white-noise will not persist across reboot." >&2
    return 0
  fi

  # Detect distro from /etc/os-release (ID), falling back to the first
  # ID_LIKE token. Pure bash (no tr/head) so it works in a sparse PATH.
  local id=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    [ -n "$id" ] || id="${ID_LIKE%% *}"
  fi
  id="${id,,}"   # lowercase (bash 4+)

  local line
  line="$(_dep_install_line "$id" "${missing[@]}" 2>/dev/null)" || line=""

  if [ -z "$line" ]; then
    # Unknown distro — tell the user what's missing and let them install.
    printf 'fakemic: missing system dependency: %s\n' "${missing[*]}" >&2
    printf 'fakemic: install it with your package manager, then re-run fakemic.\n' >&2
    exit 1
  fi

  # Non-interactive (pipe/script/systemd) — print the exact command and bail.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf 'fakemic: missing system dependency: %s\n' "${missing[*]}" >&2
    printf 'fakemic: install with:  sudo %s\n' "$line" >&2
    exit 1
  fi

  # Interactive — offer to install now.
  printf 'fakemic: missing system dependency: %s\n' "${missing[*]}"
  printf 'fakemic: this needs root. Install now with:\n  %s%s%s\n' "$CB" "sudo $line" "$C0"
  printf 'Proceed? [Y/n] '
  local ans; read -r ans
  case "$ans" in
    n|N|no|NO|No) die "install the dependency above, then re-run fakemic." ;;
  esac
  # shellcheck disable=SC2086
  sudo $line || die "dependency installation failed (ran: sudo $line)"
  local c
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' still not found after install"
  done
  command -v systemctl >/dev/null 2>&1 || \
    echo "fakemic: warning: systemctl not found; white-noise will not persist across reboot." >&2
}

# --- carrier ----------------------------------------------------------------
sink_exists() { pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$FAKEMIC_NAME"; }

load_carrier() {
  # The sink_properties string is passed verbatim (single-quoted) so PipeWire's
  # spa-json parser sees device.description="Fake Microphone" with the monitor
  # inheriting priority 9000 (above real mics at ~2000).
  pactl load-module module-null-sink \
    sink_name="$FAKEMIC_NAME" \
    'sink_properties="device.description=\"Fake Microphone\" device.icon_name=\"audio-input-microphone\" priority.session=9000 priority.driver=9000"' \
    >/dev/null 2>&1
}

ensure_carrier() {
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  if ! sink_exists; then
    load_carrier || die "failed to create the fake_mic sink"
  fi
  if [ ! -f "$CONF_FILE" ]; then
    cat > "$CONF_FILE" <<'EOF'
# Managed by `fakemic`. Recreates the fake_mic null-sink on PipeWire startup.
context.modules = [
    { name = libpipewire-module-null-sink
      args = {
          sink_name = fake_mic
          sink_properties = "device.description=\"Fake Microphone\" device.icon_name=\"audio-input-microphone\" priority.session=9000 priority.driver=9000"
      }
    }
]
EOF
  fi
}

fake_mic_module_id() {
  pactl list short modules 2>/dev/null | grep 'module-null-sink' | grep 'sink_name=fake_mic' | awk '{print $1}'
}

unload_carrier() {
  local id; id="$(fake_mic_module_id)"
  [ -n "$id" ] && pactl unload-module "$id" >/dev/null 2>&1 || true
}

# --- default source ---------------------------------------------------------
current_default_source() { pactl get-default-source 2>/dev/null; }

set_fake_default() {
  local cur; cur="$(current_default_source)"
  if [ -n "$cur" ] && [ "$cur" != "$FAKEMIC_MONITOR" ] && [ ! -f "$PREV_DEFAULT_FILE" ]; then
    printf '%s\n' "$cur" > "$PREV_DEFAULT_FILE"
  fi
  pactl set-default-source "$FAKEMIC_MONITOR" >/dev/null 2>&1 \
    || die "failed to set fake_mic.monitor as default source"
}

best_real_source() {
  pactl -f json list sources 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
c=[]
for s in d:
    n=s.get("name","")
    p=s.get("properties") or {}
    if not n or n=="fake_mic.monitor" or p.get("device.class")=="monitor": continue
    c.append((int(p.get("priority.session") or 0), n))
c.sort(reverse=True)
print(c[0][1] if c else "")
'
}

restore_real_default() {
  local tgt=""
  [ -f "$PREV_DEFAULT_FILE" ] && tgt="$(cat "$PREV_DEFAULT_FILE" 2>/dev/null)"
  if [ -z "$tgt" ] || [ "$tgt" = "$FAKEMIC_MONITOR" ]; then tgt="$(best_real_source)"; fi
  if [ -n "$tgt" ]; then
    pactl set-default-source "$tgt" >/dev/null 2>&1 \
      && printf '%s✓%s default source restored -> %s%s%s\n' "$CG" "$C0" "$CB" "$tgt" "$C0"
  fi
  rm -f "$PREV_DEFAULT_FILE"
}

# --- feeder (white noise) ---------------------------------------------------
install_service() {
  [ -d "$UNIT_DIR" ] || mkdir -p "$UNIT_DIR"
  # Resolve the real `fakemic` launcher (pipx/uv put it in a venv bin dir, not
  # /usr/local/bin). Fall back to $0 if it's not on PATH (direct install case).
  local bin; bin="$(command -v fakemic 2>/dev/null || true)"
  [ -n "$bin" ] || bin="$0"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=fakemic white-noise feeder
After=pipewire.service pipewire-pulse.service wireplumber.service
Wants=pipewire-pulse.service

[Service]
Type=exec
Environment=PULSE_SINK=fake_mic
ExecStart=$bin _feeder
Restart=always
RestartSec=3
# keep the noise out of the real output if anything goes wrong
ProtectSystem=false

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

feeder_active()  { systemctl --user is-active --quiet  "$UNIT_NAME" 2>/dev/null; }
feeder_enabled() { systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; }

start_feeder() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl required for white-noise mode"
  install_service
  systemctl --user enable --now "$UNIT_NAME" >/dev/null 2>&1 \
    || die "failed to start the white-noise feeder (systemctl --user enable --now)"
}

stop_feeder() {
  systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
}

# Internal: run by the systemd unit. Refuses to play unless fake_mic exists.
_feeder() {
  detect_session || exit 1
  local i
  for i in $(seq 1 60); do
    sink_exists && break
    sleep 0.5
  done
  if ! sink_exists; then
    echo "fakemic: fake_mic sink not available; refusing to play noise (no redirect to real output)." >&2
    exit 1
  fi
  export PULSE_SINK="$FAKEMIC_NAME"
  exec sox -n -t pulseaudio -r 48000 -c 2 synth "$NOISE_SECS" whitenoise gain "$NOISE_GAIN"
}

# --- subcommands ------------------------------------------------------------
cmd_silent() {
  detect_session; check_deps
  ensure_carrier
  stop_feeder
  set_fake_default
  printf 'silent\n' > "$MODE_FILE"
  printf '%s✓%s Fake microphone: %s%sSILENT%s — set as default capture.\n' \
    "$CG" "$C0" "$CC" "$CB" "$C0"
  printf "Browsers will use '%sMonitor of Fake Microphone%s' (silence) by default.\n" "$CB" "$C0"
}

cmd_white() {
  detect_session; check_deps
  ensure_carrier
  start_feeder
  set_fake_default
  printf 'white\n' > "$MODE_FILE"
  printf '%s✓%s Fake microphone: %s%sWHITE NOISE%s — set as default capture.\n' \
    "$CG" "$C0" "$CY" "$CB" "$C0"
  printf "Browsers will use '%sMonitor of Fake Microphone%s' (white noise) by default.\n" "$CB" "$C0"
}

cmd_clear() {
  detect_session; check_deps
  stop_feeder                 # stop feeder BEFORE removing the carrier (no redirect)
  unload_carrier
  rm -f "$CONF_FILE" "$MODE_FILE" "$UNIT_FILE"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  restore_real_default
  printf '%s✓%s Fake microphone removed. %sNormal audio restored.%s\n' "$CG" "$C0" "$CC" "$C0"
}

cmd_status() {
  detect_session; check_deps
  local mode="none"; [ -f "$MODE_FILE" ] && mode="$(cat "$MODE_FILE" 2>/dev/null)"
  local def prev="none"
  def="$(current_default_source)"
  [ -f "$PREV_DEFAULT_FILE" ] && prev="$(cat "$PREV_DEFAULT_FILE" 2>/dev/null)"

  local mode_word
  case "$mode" in
    silent) mode_word="${CC}${CB}silent${C0}" ;;
    white)  mode_word="${CY}${CB}white${C0}"  ;;
    *)      mode_word="${CD}none${C0}" ;;
  esac
  local def_word
  if [ "$def" = "$FAKEMIC_MONITOR" ]; then def_word="${CG}${CB}${def}${C0}"; else def_word="${CB}${def}${C0}"; fi

  printf '%s%sfakemic state%s\n' "$CB" "$CC" "$C0"
  printf "  %s%-22s%s : %s\n" "$CD" "configured mode"         "$C0" "$mode_word"
  printf "  %s%-22s%s : %s\n" "$CD" "carrier (fake_mic sink)" "$C0" "$(sink_exists  && state_word 1 present  absent  || state_word 0 present  absent)"
  printf "  %s%-22s%s : %s\n" "$CD" "pipewire config drop-in" "$C0" "$([ -f "$CONF_FILE" ] && state_word 1 installed missing || state_word 0 installed missing)"
  printf "  %s%-22s%s : %s (%s, %s)\n" "$CD" "feeder unit" "$C0" \
    "$(feeder_active  && state_word 1 active   inactive || state_word 0 active   inactive)" \
    "$([ -f "$UNIT_FILE" ] && echo 'file present' || echo 'no file')" \
    "$(feeder_enabled && state_word 1 enabled  disabled || state_word 0 enabled  disabled)"
  printf "  %s%-22s%s : %s\n" "$CD" "current default source"  "$C0" "$def_word"
  printf "  %s%-22s%s : %s\n" "$CD" "saved previous default"  "$C0" "${CB}${prev}${C0}"
  echo
  printf '%s%scapture sources%s %s(what browsers see, by priority)%s\n' "$CB" "$CC" "$C0" "$CD" "$C0"
  pactl -f json list sources 2>/dev/null | python3 -c '
import sys,json,os
col = os.environ.get("FAKEMIC_COLOR") == "1"
B="\033[1m"; D="\033[2m"; G="\033[32m"; R="\033[0m"
if not col: B=D=G=R=""
try: d=json.load(sys.stdin)
except Exception: print("  (unable to enumerate)"); sys.exit(0)
rows=[]
for s in d:
    n=s.get("name",""); desc=s.get("description","")
    p=s.get("properties") or {}
    pr=int(p.get("priority.session") or 0)
    cls=p.get("device.class") or "-"
    rows.append((pr,n,desc,cls))
rows.sort(reverse=True)
for pr,n,desc,cls in rows:
    if n=="fake_mic.monitor":
        print(f" {G}{B}*[{pr:>5}] {desc}  ({n})  class={cls}{R}")
    elif cls=="monitor":
        print(f"   {D}[{pr:>5}] {desc}  ({n})  class={cls}{R}")
    else:
        print(f"   [{pr:>5}] {desc}  ({n})  class={cls}")
' || echo "  (unable to enumerate sources)"
}

usage() {
  cat <<EOF
${CB}${CC}fakemic${C0} — fake virtual microphone manager

${CB}Usage:${C0}
  ${CB}fakemic silent${C0}   create/ensure a ${CC}SILENT${C0} fake mic, make it the default
  ${CB}fakemic white${C0}    create/ensure a ${CY}WHITE-NOISE${C0} fake mic, make it the default
  ${CB}fakemic clear${C0}    remove the fake mic and restore normal audio
  ${CB}fakemic status${C0}   show current state and available microphones
  ${CB}fakemic help${C0}     show this help

The fake mic becomes the default capture device, so browsers list it first
and pre-select it. State survives reboot (PipeWire config drop-in + a per-user
systemd unit for the white-noise feeder).

${CD}Environment overrides:${C0}
  ${CD}FAKEMIC_NOISE_GAIN${C0}  white-noise level in dBFS (default -20)
  ${CD}FAKEMIC_NOISE_SECS${C0}  seconds per feeder stream (default 86400)
EOF
}

case "${1:-help}" in
  silent)    cmd_silent ;;
  white)     cmd_white ;;
  clear)     cmd_clear ;;
  status)    cmd_status ;;
  help|-h|--help|"") usage ;;
  _feeder)   _feeder ;;
  *) echo "fakemic: unknown command '$1'" >&2; usage; exit 1 ;;
esac