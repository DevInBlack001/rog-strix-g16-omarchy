# Hardware detection: why `check.sh` might say N/A

`check.sh` fingerprints the machine it's running on before checking
anything, so it can tell the difference between "this fix is broken" and
"this fix doesn't apply to your hardware." If you're running this on
something other than a G615JMR, expect a wall of `N/A`, that's the intended
result, not a bug.

## The four outcomes

```
PASS  the fix's hardware is present and the fix is correctly in place
FAIL  the fix's hardware is present and the fix is missing or wrong
N/A   this machine doesn't match the hardware the fix targets, skipped
warn  informational, doesn't affect the exit code either way
```

Only `FAIL` sets a non-zero exit. A machine that reports every check as
`N/A` exits 0, correctly, because nothing that applies to it is broken.

## What gets fingerprinted

`lib/hardware-detect.sh`, sourced by both `check.sh` and `install.sh`,
detects:

| Signal | How | Used to gate |
|---|---|---|
| Board name | `/sys/class/dmi/id/board_name` | keyboard zone patch, s2idle-vs-S3, warm-idle fix |
| CPU vendor | `/proc/cpuinfo` | VMD (Intel-only feature) |
| GPU vendor(s) | `lspci -nn`, PCI vendor ID | NVIDIA sleep units |
| Audio codec | `/proc/asound/cards` + `codec#0`, **not** a hardcoded card index | audio section overall |
| TAS2781 amp | `lsmod` | s2idle-forcing, warm-idle fix |
| ASUS N-KEY keyboard | `lsusb` / sysfs, USB ID `0b05:19b6` | keyboard zone patch |

The audio codec's card index is discovered, not assumed. Card indices are
assigned in probe order and shift with whatever else is plugged in or how
the kernel happens to enumerate the dGPU's HDMI/DP audio function on a
given boot, so `card0` is not a safe constant even on the reference
machine, let alone someone else's.

## Applicability is gated on the narrowest verified signal, not the broadest plausible one

The suspend-then-hibernate fix in [suspend.md](suspend.md) exists because
Raptor Lake-HX has no S0ix. The obvious generalization was: any machine
whose `/sys/power/suspend_stats/total_hw_sleep` counter is absent probably
has the same problem, so warn there too.

Tested against an unrelated HP laptop (Conexant codec, no discrete GPU, no
ASUS anything) and that heuristic false-FAILed: the counter is absent there
for reasons that have nothing to do with the ~2.65 W warm-idle number this
repo measured on the G615JMR. So the hard PASS/FAIL for that fix is gated
on the board family it was actually measured on (`is_g615_board`).
Everything else gets an advisory note (`total_hw_sleep` on your platform is
worth checking after a real suspend) instead of a verdict this repo can't
back up.

The general rule going forward, see `CLAUDE.md` for the fuller version:
a hardcoded-feeling but verified gate beats a broader but speculative one.

## If you're on different hardware

Every `N/A` line names what it's not matching. Read it as: this repo has
nothing to say about that part of your machine, not: something is broken.
If you have a G615-series board that reports something unexpected, or want
to add detection for a different board or codec entirely, see
`CLAUDE.md`, "Generalizing to other hardware and brands," for the current
plan and how a contributed profile would slot in.
