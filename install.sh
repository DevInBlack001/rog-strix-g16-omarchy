#!/usr/bin/env bash
#
# Apply the ROG Strix G16 (G615JMR) fixes to an Omarchy / Arch install.
#
# Everything here is idempotent: re-running changes nothing that is already
# correct. Nothing is overwritten without a .bak.<epoch> beside it.
#
#   ./install.sh              apply everything
#   ./install.sh --dry-run    print what would change, touch nothing
#   ./install.sh audio sleep  apply only the named sections
#
# Sections: audio sleep keyboard nvidia menu
#
# NOT covered here because it cannot be scripted -- see docs/bios.md. Disabling
# Intel VMD in the BIOS is the single biggest win on this machine (-8.5 W idle)
# and no amount of OS config substitutes for it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%s)"
DRY=0
CHANGED=0

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=; G=; Y=; R=; D=; N=
fi

section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
ok()      { printf '  %s.%s %s\n'      "$G" "$N" "$1"; }
act()     { printf '  %s+%s %s\n'      "$Y" "$N" "$1"; CHANGED=$((CHANGED+1)); }
warn()    { printf '  %s!%s %s\n'      "$R" "$N" "$1"; }
note()    { printf '    %s%s%s\n'      "$D" "$1" "$N"; }

# ------------------------------------------------------------- primitives ----

# install_file <src-relative-to-repo> <dest> [mode]
# Copies only when the content differs. Backs up any file it replaces.
install_file() {
  local src="$REPO/$1" dest="$2" mode="${3:-644}" sudo_=""
  [[ "$dest" == /home/* || "$dest" == "$HOME"/* ]] || sudo_="sudo"

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    ok "$dest"
    return
  fi

  if [[ -e "$dest" ]]; then
    act "$dest ${D}(replacing, backup at ${dest}.bak.${STAMP})${N}"
    (( DRY )) || $sudo_ cp -a "$dest" "$dest.bak.$STAMP"
  else
    act "$dest"
  fi

  (( DRY )) && return
  $sudo_ install -Dm"$mode" "$src" "$dest"
}

need_pkg() {
  pacman -Qq "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------ preflight -----

preflight() {
  section "Preflight"

  local board
  board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
  if [[ "$board" == G615* ]]; then
    ok "board $board"
  else
    warn "board reads '$board', not a G615* ROG Strix G16"
    note "These fixes are written for the G615JMR. On another board the audio"
    note "and keyboard sections are likely wrong. Ctrl-C now unless you know"
    note "what you are doing."
    sleep 5
  fi

  if [[ -r /etc/os-release ]] && grep -q '^ID=omarchy' /etc/os-release; then
    ok "Omarchy"
  else
    note "Not Omarchy -- everything except the menu section still applies."
  fi

  if (( DRY )); then
    printf '\n  %sdry run: nothing will be written%s\n' "$Y" "$N"
  fi
}

# ---------------------------------------------------------------- audio -----

do_audio() {
  section "Audio (ALC294 + TAS2781 amps)"

  install_file etc/modprobe.d/90-snd-hda-no-powersave.conf \
               /etc/modprobe.d/90-snd-hda-no-powersave.conf

  install_file home/.config/wireplumber/wireplumber.conf.d/50-no-suspend-builtin-audio.conf \
               "$HOME/.config/wireplumber/wireplumber.conf.d/50-no-suspend-builtin-audio.conf"

  # The soft-mixer drop-in is the root cause of the recurring silence: with it
  # set, PipeWire's ACP applies its downward mixer writes on every port switch
  # but never the matching upward ones. See docs/audio.md.
  local sm
  for sm in "$HOME"/.config/wireplumber/wireplumber.conf.d/*.conf; do
    [[ -f "$sm" ]] || continue
    grep -q 'api\.alsa\.soft-mixer' "$sm" || continue
    act "disabling $(basename "$sm") ${D}(sets api.alsa.soft-mixer)${N}"
    note "This is the one-way ratchet to silence. Renamed, not deleted."
    (( DRY )) || mv "$sm" "$sm.disabled-$STAMP"
  done

  # A gain-pinning login unit fights ACP once soft-mixer is gone: it unmutes
  # both paths and forces Auto-Mute Enabled, the opposite of what ACP wants.
  if systemctl --user is-enabled omarchy-fix-alsa-gain.service >/dev/null 2>&1; then
    act "disabling omarchy-fix-alsa-gain.service ${D}(conflicts with ACP)${N}"
    (( DRY )) || systemctl --user disable --now omarchy-fix-alsa-gain.service
  fi

  # A late boot-time writer can silently override modprobe.d. This one bit us.
  if [[ -x /usr/local/bin/omarchy-powersave-tune ]] \
     && grep -qE '^[^#]*snd_hda_intel/parameters/power_save' /usr/local/bin/omarchy-powersave-tune 2>/dev/null; then
    warn "/usr/local/bin/omarchy-powersave-tune writes power_save at boot"
    note "It runs after modprobe, so it silently overrides the modprobe.d file."
    note "Comment that line out by hand; see docs/audio.md."
  fi

  if (( ! DRY )); then
    systemctl --user restart wireplumber 2>/dev/null || true
  fi
  note "power_save takes effect on reboot (or: sudo modprobe -r snd_hda_intel)"
}

# ---------------------------------------------------------------- sleep -----

do_sleep() {
  section "Suspend / hibernate"

  install_file etc/tmpfiles.d/zz-s2idle.conf \
               /etc/tmpfiles.d/zz-s2idle.conf

  install_file etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf \
               /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf

  install_file etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf \
               /etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf

  # Omarchy's lock-before-suspend inhibitor needs longer than the 5 s default
  # when a lid close also reconfigures displays.
  install_file etc/systemd/logind.conf.d/20-inhibit-delay.conf \
               /etc/systemd/logind.conf.d/20-inhibit-delay.conf

  if (( ! DRY )); then
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/zz-s2idle.conf >/dev/null 2>&1 || true
  fi

  # mem_sleep_default=deep on the cmdline contradicts the tmpfiles rule. The
  # tmpfiles rule wins today, but leaving both in place is a trap for whoever
  # reads the cmdline next.
  if grep -q 'mem_sleep_default=deep' /proc/cmdline; then
    warn "kernel cmdline still carries mem_sleep_default=deep"
    note "Harmless today (the tmpfiles rule overrides it) but contradictory."
    note "Remove it by hand -- see docs/suspend.md. Not scripted: editing the"
    note "bootloader config wrong leaves you unbootable."
  fi

  # Hibernation must actually be provisioned or suspend-then-hibernate is a
  # 30-minute countdown to nothing.
  if command -v omarchy-hibernation-available >/dev/null 2>&1; then
    if omarchy-hibernation-available >/dev/null 2>&1; then
      ok "hibernation provisioned"
    else
      warn "hibernation is NOT available -- suspend-then-hibernate will not hibernate"
      note "Run: omarchy-hibernate-setup  (or see docs/suspend.md)"
    fi
  elif ! grep -q '^resume=' /proc/cmdline && ! grep -q 'resume=' /proc/cmdline; then
    warn "no resume= on the kernel cmdline; hibernation will not resume"
  fi
}

# --------------------------------------------------------------- nvidia -----

do_nvidia() {
  section "NVIDIA sleep units"

  if ! lspci -d 10de: >/dev/null 2>&1 || ! lspci | grep -qi nvidia; then
    note "no NVIDIA GPU found, skipping"
    return
  fi

  local u missing=()
  for u in nvidia-suspend nvidia-hibernate nvidia-resume nvidia-suspend-then-hibernate; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1 \
       && systemctl cat "$u.service" >/dev/null 2>&1; then
      if [[ "$(systemctl is-enabled "$u.service" 2>/dev/null)" == enabled ]]; then
        ok "$u.service"
      else
        missing+=("$u.service")
      fi
    else
      warn "$u.service not installed ${D}(nvidia-utils missing?)${N}"
    fi
  done

  if (( ${#missing[@]} )); then
    act "enabling ${missing[*]}"
    note "Arch ships these disabled. Without them hibernate resume dies with -5."
    (( DRY )) || sudo systemctl enable "${missing[@]}"
  fi
}

# ------------------------------------------------------------- keyboard -----

do_keyboard() {
  section "Keyboard RGB zones (asusd)"

  if ! need_pkg asusctl; then
    note "asusctl not installed, skipping"
    note "Install it for fan curves, RGB and power profiles: pacman -S asusctl"
    return
  fi

  install_file usr/local/bin/asusd-aura-zones /usr/local/bin/asusd-aura-zones 755
  install_file etc/pacman.d/hooks/zz-asusd-aura-zones.hook \
               /etc/pacman.d/hooks/zz-asusd-aura-zones.hook

  if (( ! DRY )); then
    if sudo /usr/local/bin/asusd-aura-zones; then
      systemctl is-active asusd >/dev/null 2>&1 && sudo systemctl restart asusd
    fi
  fi
}

# ----------------------------------------------------------------- menu -----

do_menu() {
  section "Omarchy menu"

  local dest="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  local key='"system.suspend"'

  if [[ ! -d "$HOME/.config/omarchy" ]]; then
    note "no ~/.config/omarchy, skipping"
    return
  fi

  if [[ -f "$dest" ]] && grep -q "$key" "$dest"; then
    ok "$dest ${D}(system.suspend already overridden)${N}"
    return
  fi

  if [[ ! -f "$dest" ]]; then
    install_file home/.config/omarchy/extensions/omarchy-menu.jsonc "$dest"
    return
  fi

  act "$dest ${D}(appending system.suspend override)${N}"
  (( DRY )) && return
  cp -a "$dest" "$dest.bak.$STAMP"
  # Insert before the final closing brace so existing entries survive.
  python3 - "$dest" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
entry = (
    '\n  // Suspend should end in hibernation rather than an open-ended s2idle:\n'
    '  // this platform has no S0ix, so a "suspended" machine still burns ~2.65 W\n'
    '  // with the fan off. See /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf.\n'
    '  "system.suspend": {"action":"systemctl suspend-then-hibernate"},\n'
)
i = src.rstrip().rfind('}')
if i == -1:
    sys.exit("omarchy-menu.jsonc has no closing brace; edit it by hand")
open(path, 'w').write(src[:i] + entry + src[i:])
PY
  command -v omarchy >/dev/null 2>&1 && omarchy restart shell >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ main -----

SECTIONS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    audio|sleep|keyboard|nvidia|menu) SECTIONS+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
(( ${#SECTIONS[@]} )) || SECTIONS=(audio sleep nvidia keyboard menu)

preflight
for s in "${SECTIONS[@]}"; do "do_$s"; done

section "Done"
if (( DRY )); then
  printf '  %d change(s) would be made.\n' "$CHANGED"
else
  printf '  %d change(s) made.\n' "$CHANGED"
  if (( CHANGED )); then
    printf '  %sReboot to pick up the modprobe and cmdline-adjacent changes.%s\n' "$B" "$N"
  fi
fi
printf '  Verify any time with: %s./check.sh%s\n' "$B" "$N"
printf '  %sThe BIOS VMD change is not applied by this script -- read docs/bios.md.%s\n' "$Y" "$N"
