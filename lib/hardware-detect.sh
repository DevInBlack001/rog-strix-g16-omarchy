#!/usr/bin/env bash
#
# Hardware fingerprinting shared by check.sh and install.sh.
#
# Every detect_* function prints one best-effort value and never errors: a
# missing or unreadable source becomes "unknown", not a failure. Every
# is_*/has_* predicate returns 0/1 and is what the per-fix applicability
# gates in check.sh (and the preflight note in install.sh) are built on.
#
# This file is deliberately just a bag of predicates, not a registry, today:
# every predicate below still only recognises the one machine this repo was
# written for. See CLAUDE.md, "Generalizing to other hardware", for the plan
# to turn this into a real per-board/per-codec lookup instead of one-off
# checks.

detect_board()      { cat /sys/class/dmi/id/board_name   2>/dev/null || echo unknown; }
detect_sys_vendor()  { cat /sys/class/dmi/id/sys_vendor    2>/dev/null || echo unknown; }
detect_bios()        { cat /sys/class/dmi/id/bios_version  2>/dev/null || echo unknown; }

detect_cpu_model() {
  sed -n 's/^model name\s*: //p' /proc/cpuinfo 2>/dev/null | head -1
}

detect_cpu_vendor() {
  if grep -qm1 GenuineIntel /proc/cpuinfo 2>/dev/null; then echo intel
  elif grep -qm1 AuthenticAMD /proc/cpuinfo 2>/dev/null; then echo amd
  else echo unknown
  fi
}

# All GPU vendors present (a hybrid laptop reports two), space-separated.
detect_gpu_vendor() {
  local pciid out=()
  for pciid in $(lspci -nn 2>/dev/null \
      | grep -Ei 'vga compatible controller|3d controller' \
      | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | cut -d: -f1 | tr -d '['); do
    case "$pciid" in
      10de) out+=(nvidia) ;;
      1002) out+=(amd) ;;
      8086) out+=(intel) ;;
      *)    out+=("$pciid") ;;
    esac
  done
  if (( ${#out[@]} )); then printf '%s\n' "${out[*]}"; else echo unknown; fi
}

has_nvidia_gpu() {
  lspci -d 10de: 2>/dev/null | grep -qi nvidia
}

# The built-in codec isn't reliably card0: card indices are assigned in probe
# order and shift with whatever else is plugged in or however the kernel
# enumerates the dGPU's HDMI/DP audio function on a given boot. Find it by
# name instead of trusting a fixed index. /proc/asound/cards lines look like:
#   0 [PCH            ]: HDA-Intel - HDA Intel PCH
#   1 [NVidia         ]: HDA-Intel - HDA NVidia
# and it's the HDMI/DP card, not necessarily the built-in one, that carries
# the GPU vendor name.
detect_builtin_audio_card() {
  awk '/HDA-Intel|HDA-AMD/ && !/NVidia|AMD\/ATI/ {print $1; exit}' \
    /proc/asound/cards 2>/dev/null
}

detect_codec_proc_path() {
  local card; card="$(detect_builtin_audio_card)"
  [[ -n "$card" ]] && echo "/proc/asound/card${card}/codec#0"
}

detect_codec_name() {
  local path; path="$(detect_codec_proc_path)"
  [[ -n "$path" ]] && sed -n 's/^Codec: *//p' "$path" 2>/dev/null | head -1
}

# TAS2781 binds late and only shows up once audio has actually initialised;
# checking the loaded module is more reliable than grepping the codec proc
# file for it.
has_tas2781_amp() {
  lsmod 2>/dev/null | grep -qi tas2781
}

has_asus_nkey_keyboard() {
  if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qi '0b05:19b6'; then
    return 0
  fi
  local vf
  for vf in /sys/bus/usb/devices/*/idVendor; do
    [[ -f "$vf" ]] || continue
    local pf="${vf%idVendor}idProduct"
    [[ "$(cat "$vf" 2>/dev/null)" == 0b05 && "$(cat "$pf" 2>/dev/null)" == 19b6 ]] && return 0
  done
  return 1
}

has_s0ix_counters() {
  [[ -e /sys/power/suspend_stats/total_hw_sleep ]]
}

# --- applicability predicates: one per class of fix in this repo ----------

# Keyboard zone patch and the theme-set hook target this exact board family.
is_g615_board() {
  [[ "$(detect_board)" == G615* ]]
}

# The s2idle-forcing / suspend-then-hibernate audio-survival fixes exist
# because of this specific amp, not because of the board as such.
is_target_amp() {
  has_tas2781_amp
}

# The soft-mixer / power_save / codec-cache audio fixes target this codec.
is_target_codec() {
  [[ "$(detect_codec_name)" == *ALC294* ]] && has_tas2781_amp
}

# VMD is an Intel-only feature; nothing here applies on AMD platforms.
is_vmd_capable_vendor() {
  [[ "$(detect_cpu_vendor)" == intel ]]
}
