# Hardware detection: why you might see N/A

Both `check.sh` and `install.sh` fingerprint the machine they're running
on before doing anything, so each can tell the difference between "this
fix is broken" (or "not applied yet") and "this fix doesn't apply to your
hardware." If you're running either on something other than a G615JMR,
expect a wall of `N/A`, that's the intended result, not a bug.

## `check.sh`'s four outcomes

```
PASS  the fix's hardware is present and the fix is correctly in place
FAIL  the fix's hardware is present and the fix is missing or wrong
N/A   this machine doesn't match the hardware the fix targets, skipped
warn  informational, doesn't affect the exit code either way
```

Only `FAIL` sets a non-zero exit. A machine that reports every check as
`N/A` exits 0, correctly, because nothing that applies to it is broken.

## `install.sh` gates the same way

Each hardware-specific section (`do_audio`, the amp and board-specific
halves of `do_sleep`, `do_keyboard`, `do_theme`, `do_menu`) checks its
matching predicate before writing anything, reporting `N/A` instead of
installing a file that does nothing useful. This isn't only a reporting
nicety: `aura_support.ron` is one file shared across every board `asusd`
knows about, so before this gate, running the keyboard section on any
machine with `asusctl` installed would rewrite the `G615JM` entry in it
regardless of whether that board was actually present. `do_keyboard` and
`do_theme` are gated on `has_asus_nkey_keyboard`, not just on `asusctl`
being installed. On unrelated hardware, `./install.sh --dry-run` now
reports `N/A` for every hardware-specific section and "0 change(s) would
be made."

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
[../ROADMAP.md](../ROADMAP.md) for the current plan and how a contributed
profile would slot in.
