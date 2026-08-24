#!/usr/bin/env bash
#
# Read-only health check for the ROG Strix G16 (G615JMR) fixes.
# Writes nothing, needs no root. Exit 0 if everything is as it should be.
#
# Every check here exists because something looked fine and wasn't. Where a
# reading is easy to misread, the note says so.

set -uo pipefail

FAIL=0

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=; G=; Y=; R=; D=; N=
fi

section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
pass()    { printf '  %s...%s %s\n' "$G" "$N" "$1"; }
fail()    { printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; FAIL=1; }
warn()    { printf '  %swarn%s %s\n' "$Y" "$N" "$1"; }
note()    { printf '       %s%s%s\n' "$D" "$1" "$N"; }

read_or() { cat "$1" 2>/dev/null || echo "$2"; }

# ----------------------------------------------------------------- board -----

section "Machine"
printf '  %-22s %s\n' "board" "$(read_or /sys/class/dmi/id/board_name '?')"
printf '  %-22s %s\n' "bios" "$(read_or /sys/class/dmi/id/bios_version '?')"
printf '  %-22s %s\n' "kernel" "$(uname -r)"

# ------------------------------------------------------------------- vmd -----

section "Intel VMD (idle power)"
if lspci -D 2>/dev/null | grep -q '^10000:'; then
  fail "NVMe still behind VMD ${D}(devices in PCI domain 10000:)${N}"
  note "VMD blocks PCIe ASPM: the package never leaves PC2 and idle costs"
  note "~8.5 W more than it needs to. No OS tuning recovers this."
  note "Fix it in the BIOS -- docs/bios.md."
else
  pass "VMD off ${D}(all devices in domain 0000)${N}"
fi

# ----------------------------------------------------------------- sleep -----

section "Suspend"
ms="$(read_or /sys/power/mem_sleep '?')"
if [[ "$ms" == *'[s2idle]'* ]]; then
  pass "mem_sleep = $ms"
else
  fail "mem_sleep = $ms ${D}(want [s2idle])${N}"
  note "Under deep/S3 the TAS2781 speaker amps resume unpowered and only a"
  note "cold boot revives them."
fi

if grep -q 'mem_sleep_default=deep' /proc/cmdline; then
  warn "kernel cmdline still has mem_sleep_default=deep"
  note "Overridden by /etc/tmpfiles.d/zz-s2idle.conf, so harmless -- but the"
  note "two disagree, which will mislead the next person. docs/suspend.md."
fi

for f in /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf \
         /etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf \
         /etc/tmpfiles.d/zz-s2idle.conf; do
  [[ -f "$f" ]] && pass "$f" || fail "missing $f"
done

if [[ "$(read_or /sys/power/suspend_stats/total_hw_sleep 0)" == 0 ]]; then
  note "total_hw_sleep = 0 is EXPECTED here: Raptor Lake-HX has no S0ix."
  note "s2idle only freezes the OS (~2.65 W measured). That is the platform"
  note "floor, not a misconfiguration -- hence suspend-then-hibernate."
fi

# ---------------------------------------------------------------- nvidia -----

section "NVIDIA sleep units"
if lspci 2>/dev/null | grep -qi nvidia; then
  for u in nvidia-suspend nvidia-hibernate nvidia-resume nvidia-suspend-then-hibernate; do
    state="$(systemctl is-enabled "$u.service" 2>/dev/null || echo missing)"
    if [[ "$state" == enabled ]]; then
      pass "$u.service"
    else
      fail "$u.service is $state ${D}(Arch ships these disabled)${N}"
      note "Without them hibernate resume dies: nv_pmops_freeze returns -5."
    fi
  done
else
  note "no NVIDIA GPU"
fi

# ----------------------------------------------------------------- audio -----

section "Audio"

ps_val="$(read_or /sys/module/snd_hda_intel/parameters/power_save '?')"
if [[ "$ps_val" == 0 ]]; then
  pass "snd_hda_intel power_save = 0"
else
  fail "snd_hda_intel power_save = $ps_val ${D}(want 0)${N}"
  note "If modprobe.d looks right but the live value disagrees, a LATE writer"
  note "is overriding it after modprobe. Check /usr/local/bin and custom units"
  note "-- not just modprobe.d/udev/tlp/PPD."
fi

if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
  if pactl list sinks 2>/dev/null | grep -q soft-mixer; then
    fail "api.alsa.soft-mixer is active"
    note "This is the one-way ratchet to silence: ACP applies its downward"
    note "mixer writes on every port switch but never the upward ones."
  else
    pass "soft-mixer not in use ${D}(PipeWire owns the hardware mixer)${N}"
  fi

  # Assert the property, not the state. A node that has not been opened since
  # WirePlumber started is legitimately `suspended`; the rule only stops an
  # *idle* node from being closed. Checking state alone false-alarms after every
  # wireplumber restart.
  if command -v pw-dump >/dev/null 2>&1; then
    read -r tmo state < <(pw-dump 2>/dev/null | python3 -c "
import json, sys
for o in json.load(sys.stdin):
    info = o.get('info') or {}
    p = info.get('props') or {}
    if p.get('node.name', '').startswith('alsa_output.pci-0000_00_1f.3'):
        print(p.get('session.suspend-timeout-seconds', 'unset'), info.get('state', '?'))
        break
else:
    print('no-node', '?')
" 2>/dev/null)

    case "$tmo" in
      0)       pass "built-in sink will not idle-suspend ${D}(timeout 0, currently $state)${N}"
               [[ "$state" == suspended ]] && note "suspended = nothing has played since wireplumber started; normal" ;;
      no-node) warn "built-in analog sink not found" ;;
      *)       fail "built-in sink suspend-timeout is '$tmo' ${D}(want 0)${N}"
               note "WirePlumber will close the PCM after 5 s idle, letting the"
               note "codec and amps drop power. Check 50-no-suspend-builtin-audio.conf." ;;
    esac
  fi
fi

# The control cache can disagree with the codec's real amp registers. amixer,
# wpctl and pactl all read the cache, so they pass while the speakers are dead.
#
# Node 0x02 = Headphone DAC, node 0x03 = Speaker DAC. One of them reading
# [0x00 0x00] is normal -- that is auto-mute muting the path that is not in use.
# BOTH at zero is the stranded-cache failure.
codec=/proc/asound/card0/codec#0
amp_of() {
  sed -n "/^Node $1 /,/^  Connection/p" "$codec" \
    | grep -m1 -o 'Amp-Out vals: *\[[^]]*\]' | grep -o '\[.*\]'
}
if [[ -r "$codec" ]]; then
  hp="$(amp_of 0x02)"; spk="$(amp_of 0x03)"
  if [[ "$hp" == '[0x00 0x00]' && "$spk" == '[0x00 0x00]' ]]; then
    fail "both DACs stranded at [0x00 0x00] = -65.25 dB (silence)"
    note "The mixer will still read 100%. The HDA driver caches amp values and"
    note "skips the write when the new value equals the cached one, so re-setting"
    note "100% is a no-op. Nudge through another value to force a real write:"
    note "  amixer -c 0 sset Speaker 50% && amixer -c 0 sset Speaker 100%"
    note "Silence on speakers AND headphones rules out the TAS2781 amps --"
    note "headphones do not pass through them. Look at the codec."
  elif [[ -n "$hp$spk" ]]; then
    pass "codec amps live ${D}(headphone $hp, speaker $spk)${N}"
    [[ "$hp"  == '[0x00 0x00]' ]] && note "headphone muted = auto-mute, nothing plugged in"
    [[ "$spk" == '[0x00 0x00]' ]] && note "speaker muted = auto-mute, headphones plugged in"
  fi
fi

if systemctl --user is-enabled omarchy-fix-alsa-gain.service >/dev/null 2>&1; then
  warn "omarchy-fix-alsa-gain.service is enabled"
  note "With soft-mixer gone this unit fights ACP -- it forces Auto-Mute"
  note "Enabled and unmutes both paths. Disable it."
fi

# -------------------------------------------------------------- keyboard -----

section "Keyboard RGB"
RON=/usr/share/asusd/aura_support.ron
if [[ -r "$RON" ]]; then
  zones="$(python3 - "$RON" <<'PY' 2>/dev/null
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'\(\s*device_name:\s*"G615JM",.*?basic_zones:\s*(\[[^\]]*\])', src, re.DOTALL)
print(m.group(1) if m else "NO-ENTRY")
PY
)"
  case "$zones" in
    '[]')       fail "G615JM declares no zones ${D}(every zoned effect returns NotSupported)${N}"
                note "Run: sudo /usr/local/bin/asusd-aura-zones && sudo systemctl restart asusd" ;;
    NO-ENTRY|'') warn "no G615JM entry in $RON ${D}(upstream may have renamed it)${N}" ;;
    *)          pass "G615JM zones = $zones" ;;
  esac
  [[ -f /etc/pacman.d/hooks/zz-asusd-aura-zones.hook ]] \
    && pass "pacman hook present ${D}(survives asusctl upgrades)${N}" \
    || fail "missing pacman hook -- the next asusctl upgrade reverts the zones"
else
  note "asusctl not installed"
fi

# ------------------------------------------------------------------ done -----

section "Result"
if (( FAIL )); then
  printf '  %sSomething is off. Read the FAIL lines above.%s\n' "$R" "$N"
else
  printf '  %sAll checks passed.%s\n' "$G" "$N"
fi
exit "$FAIL"
