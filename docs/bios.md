# Disable Intel VMD

**This is the most valuable change in the repo and the only one you have to make
by hand.**

```
VMD on    21.5 W idle    4.0 h on the 88.1 Wh battery
VMD off   13.0 W idle    6.8 h              (−8.5 W, −39%)
```

## Why

Intel VMD (Volume Management Device) puts the NVMe controllers behind a
synthetic PCIe domain. Links managed that way can't negotiate ASPM, so the CPU
package never gets below PC2 and sits there burning 8–12 W it doesn't need to.

The measured penalty matched that theory exactly. Nothing in userspace recovers
it — see "what doesn't work" below.

## Doing it

BIOS → Advanced → **VMD setup menu** → *Enable VMD controller* → **Disabled**.

Linux boots straight afterwards with **no initramfs rebuild needed**. The two
NVMe drives leave the `10000:` PCI domain and enumerate normally in domain
`0000`. Confirm with:

```sh
lspci -D | grep -i nvme      # no 10000: prefix any more
./check.sh                   # the VMD section will pass
```

> BIOS re-enumerated the two drives in the **opposite order** after the change.
> Identify disks by size or label, never by PCI address.

## If you dual-boot Windows — read this first

**Windows will not boot with VMD off** until you prepare it. Its boot-critical
storage driver is Intel `iaStorVD`, and `stornvme` is disabled via
`StartOverride`. Flipping VMD without this leaves Windows unbootable
(`INACCESSIBLE_BOOT_DEVICE`).

It's a one-time fix, done **from Windows, with VMD still enabled**:

1. **If C: is BitLocker-encrypted, suspend protection first.** Changing storage
   mode alters TPM PCRs and Windows will demand your recovery key on the next
   boot. Have the key to hand regardless.
   ```
   manage-bde -protectors -disable C: -rebootcount 3
   ```
2. Tell Windows to come up in Safe Mode, where it loads the inbox NVMe driver:
   ```
   bcdedit /set {current} safeboot minimal
   ```
3. Reboot into the BIOS, disable VMD, and let Windows boot into Safe Mode. It
   installs `stornvme` on the way.
4. Back in Windows, return to a normal boot:
   ```
   bcdedit /deletevalue {current} safeboot
   ```

After that VMD stays off permanently and both operating systems boot.

**Do not "solve" this by leaving VMD on.** That costs 8.5 W and 2.8 hours of
battery on every single Linux session, forever, and there is no OS-level
mitigation.

## What doesn't work

Measured on this machine, all of it, before finding VMD:

| Tweak | Effect |
|---|---|
| 165 Hz → 60 Hz panel | 0.27 W |
| PCI runtime PM | no measurable change |
| USB autosuspend | no measurable change |
| `panel_od` off | no measurable change |
| Audio idle tuning | no measurable change |
| Wi-Fi powersave | no measurable change |

## Measuring battery draw without fooling yourself

Three consecutive measurements were invalidated before a clean one landed.
Before you trust any number:

- `/sys/class/power_supply/BAT0/status` must read **`Discharging`**. Charging
  masks draw entirely.
- The dGPU must be asleep:
  `/sys/bus/pci/devices/0000:01:00.0/power/runtime_status` = `suspended`. An
  awake RTX 5060 adds 5–13 W and swamps whatever you're measuring.
- **Never poll `nvidia-smi` during a measurement.** Each call wakes the GPU and
  blocks runtime suspend — the observer creates the problem. sysfs only.
- **Unplug HDMI.** It's wired to the dGPU (`card1-HDMI-A-1`; the internal eDP is
  on the iGPU as `card2`), so a plugged cable keeps the card awake.
- Don't run `turbostat` alongside a battery sample — it wakes every CPU on every
  interval.
- Sample `power_now` over **≥15 readings**. `energy_now` moves in 882000 µWh
  steps (1% of capacity), so short-window energy deltas are pure quantization
  noise.

Also: this CPU has **no PC10 or S0ix counters** — Raptor Lake-HX doesn't
implement them. `turbostat` errors with `Counter 'Pkg%pc10' can not be added`
and the LPIT sysfs counters read a constant 0. That's not evidence of anything.
Use `Pkg%pc2`/`pc3`/`pc6`, and prefer a bare `turbostat --Summary --quiet` over
an explicit `--show` list so it only prints counters that exist.
