#!/usr/bin/env bash
#
# Remove everything install.sh added and put the machine back to stock.
#
#   ./uninstall.sh              revert everything
#   ./uninstall.sh --dry-run    print what would change
#
# Backups (*.bak.<epoch>) are left alone -- delete them yourself when you are
# happy. The BIOS VMD setting is not touched; change it back in the BIOS if you
# want it, and read docs/bios.md first if you dual-boot Windows.

set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && DRY=1

if [[ -t 1 ]]; then B=$'\e[1m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'; else B=; Y=; D=; N=; fi

rm_file() {
  local f="$1" sudo_=""
  [[ "$f" == "$HOME"/* ]] || sudo_="sudo"
  if [[ -e "$f" ]]; then
    printf '  %s-%s %s\n' "$Y" "$N" "$f"
    (( DRY )) || $sudo_ rm -f "$f"
  fi
}

printf '%s== Removing%s\n' "$B" "$N"
rm_file /etc/tmpfiles.d/zz-s2idle.conf
rm_file /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf
rm_file /etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf
rm_file /etc/systemd/logind.conf.d/20-inhibit-delay.conf
rm_file /etc/modprobe.d/90-snd-hda-no-powersave.conf
rm_file /etc/pacman.d/hooks/zz-asusd-aura-zones.hook
rm_file /usr/local/bin/asusd-aura-zones
rm_file "$HOME/.config/wireplumber/wireplumber.conf.d/50-no-suspend-builtin-audio.conf"
rm_file "$HOME/.local/bin/omarchy-theme-set-keyboard-zones"
rm_file "$HOME/.config/omarchy/hooks/theme-set.d/omarchy-theme-set-keyboard-zones"
rm_file "$HOME/.config/omarchy/hooks/post-boot.d/omarchy-theme-set-keyboard-zones"

printf '\n%s== Left in place, revert by hand if you want them%s\n' "$B" "$N"
printf '  %s%s%s\n' "$D" "aura_support.ron keeps the patched zones until the next asusctl upgrade" "$N"
printf '  %s%s%s\n' "$D" "the nvidia-*.service sleep units stay enabled (harmless, and needed for hibernate)" "$N"
printf '  %s%s%s\n' "$D" "the system.suspend override in ~/.config/omarchy/extensions/omarchy-menu.jsonc" "$N"
printf '  %s%s%s\n' "$D" "any *.disabled-<epoch> wireplumber drop-in -- rename it back to re-enable" "$N"

if (( ! DRY )); then
  systemctl --user restart wireplumber 2>/dev/null || true
  printf '\n  %sReboot to restore stock suspend and audio power behaviour.%s\n' "$B" "$N"
fi
