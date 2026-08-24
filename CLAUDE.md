# CLAUDE.md

## What this repo is

Not an application. It's a documented set of fixes for running Omarchy
(Arch + Hyprland) on one specific laptop: ASUS ROG Strix G16, board
`G615JMR`. Three shell entry points apply/verify/revert config drop-ins;
everything else is either a config file installed verbatim or a doc
explaining why that file exists.

Close G615-series siblings are expected to mostly work; the audio and
keyboard fixes are pinned to this exact codec (ALC294 + TAS2781,
`1043:1204`) and keyboard (`0b05:19b6`) and may not apply elsewhere.

## Layout

```
install.sh   apply, idempotent, --dry-run, per-section (audio sleep keyboard nvidia theme menu)
uninstall.sh revert what install.sh did
check.sh     read-only diagnostics, exit non-zero if something's off

etc/…        system files, installed to the same absolute path (needs sudo)
usr/local/bin/asusd-aura-zones               packaged-file patcher (Python)
home/.local/bin/omarchy-theme-set-keyboard-zones   theme hook (Bash+Python)
home/.config/…                               user files, installed under $HOME

docs/*.md    one file per problem area: root cause, dead ends, how to
             re-diagnose a relapse. This is where the actual reasoning lives.
```

Every doc and every installed config file explains *why*, not just *what*.
When adding or changing a fix, preserve that: a fact without the reasoning
behind it (why the naive fix fails, what red herring it looks like) is
worth much less in this repo than in ordinary application code.

## Conventions to follow when editing

- **install.sh sections are independent and idempotent.** `install_file()`
  no-ops if content already matches, and backs up anything it replaces to
  `<file>.bak.<epoch>` (never deletes). Keep new sections consistent with
  this: safe to re-run, safe to run partially (`./install.sh <section>`),
  never silently clobber existing user state.
- **Root cause over symptom suppression.** The pattern throughout is:
  find the actual mechanism (e.g. `api.alsa.soft-mixer`'s one-way ratchet,
  VMD blocking ASPM, asusd's stale `aura_support.ron` entry), fix that, and
  document the plausible-but-wrong fixes that were tried first so nobody
  re-treads them.
- **Note which diagnostics lie on this hardware** before trusting a
  reading. Known-misleading ones already documented in the README and
  `check.sh`: ALSA mixer/`amixer`/`wpctl`/`pactl` read a control cache that
  can desync from the codec's real amp registers; dGPU `runtime_status`
  doesn't update across a system suspend; `nvidia-smi` wakes the GPU it's
  measuring; `modprobe -c` shows intent, not the live parameter (a late
  boot-time writer can override it); `total_hw_sleep`/PC10 counters are
  always 0 on this CPU (no S0ix on Raptor Lake-HX) and that's normal, not a
  bug.
- **Anything that can leave the machine unbootable is manual, not
  scripted.** VMD (BIOS-only, see `docs/bios.md`) and the
  `mem_sleep_default=deep` cmdline cleanup are deliberately left as
  documented manual steps rather than automated.
- **No passwordless sudo on the target machine.** `install.sh` uses plain
  `sudo` assuming an interactive human; don't switch this to something
  that assumes non-interactive privilege escalation.
- **Comment style:** rationale-heavy. Explain the *why* (mechanism, prior
  failure, what it costs to change) inline in scripts and configs, the way
  the existing files do, this repo is meant to stop someone from undoing
  a fix six months later without knowing why it's there.
- **No em dashes**, anywhere: not in comments, not in commits, not in docs.
  Use a comma, a colon when introducing a gloss or definition, or a full
  stop when a comma would join two clauses badly. Matches the style already
  set in the README and `docs/*.md` (see `3b1808f` and `5f513fa`).

## Hardware detection and applicability gating

`lib/hardware-detect.sh` is a shared, sourced-not-executed library of
`detect_*` (best-effort value, never errors, "unknown" on failure) and
`is_*`/`has_*` (0/1 predicate) functions: board, sys vendor, BIOS, CPU
vendor/model, GPU vendor(s), the built-in audio codec (found by scanning
`/proc/asound/cards` for the non-HDMI HDA card, **not** a hardcoded `card0`
index, since card indices shift with enumeration order), the TAS2781 amp
(via `lsmod`), and the ASUS N-KEY keyboard (via `lsusb`/sysfs, USB ID
`0b05:19b6`). No usernames, absolute home directories, or fixed device
indices are hardcoded anywhere in it or in the scripts that source it,
everything is either a standard kernel-exposed path under `/sys` or `/proc`
(same path on every Linux machine, not user- or install-specific) or
computed at runtime (`$HOME`, `$REPO` via `BASH_SOURCE`, the audio card
index, etc.).

`check.sh` sources this library and fingerprints the machine first (a
"Machine" section printing board/vendor/CPU/GPU/codec/amp/keyboard), then
gates every fix-specific check behind the matching predicate before running
it. Four outcomes, only one of which affects the exit code:

- **PASS**: the fix's hardware is present and the fix is correctly in place
- **FAIL**: the fix's hardware is present and the fix is missing/wrong
  (this is the only outcome that sets a non-zero exit)
- **N/A**: this machine doesn't match the hardware the check targets, so
  the check is skipped rather than false-failing
- **warn**: informational, doesn't affect PASS/FAIL/exit either way

Applicability is intentionally gated on the *narrowest* signal that's
actually been verified, not the broadest plausible one. Example: the
suspend-then-hibernate fix exists because Raptor Lake-HX has no S0ix, and
"no `total_hw_sleep` counter" looked like a good stand-in for "no S0ix",
but testing this on an unrelated HP laptop showed that heuristic false-FAILs
on hardware that simply doesn't expose the counter for unrelated reasons.
The hard PASS/FAIL there is gated on `is_g615_board` (the board family this
was actually measured on); everything else gets an advisory note instead of
a verdict. Prefer that pattern when adding new checks: a hardcoded-feeling
but *verified* gate over a broader but speculative one.

`install.sh`'s `preflight()` uses the same library for its board/amp/
keyboard warnings, so the two scripts can't drift out of sync on what
"matches this hardware" means. `install.sh`'s per-section apply logic
(`do_audio`, `do_keyboard`, etc.) is **not** yet gated the same way. It
still applies unconditionally once a section is selected, only guarded by
existing tool-presence checks (`need_pkg asusctl`, `lspci -d 10de:`). See
"Generalizing to other hardware" below for where that's headed.

## Generalizing to other hardware and brands

Current state: `lib/hardware-detect.sh` has predicates for exactly one
machine's hardware (`is_target_amp`, `is_target_codec`, `is_g615_board`,
plus the vendor-level `is_vmd_capable_vendor`/`has_nvidia_gpu` which are
already generic). `check.sh` uses them to report applicability; `install.sh`
does not yet refuse to apply a fix on hardware it doesn't match.

The fixes themselves mostly *can't* generalize: they're keyed to exact
hardware behavior (this codec's node addresses, this board's
`aura_support.ron` entry, this specific i2c failure mode). What can
generalize is the scaffolding around them. Planned direction, roughly in
order:

1. **Gate `install.sh`'s apply logic, not just its warnings.** Each
   `do_*` function should check the matching `is_*`/`has_*` predicate
   before writing anything hardware-specific, the way `check.sh` already
   does for reporting. Falls out of the same library `check.sh` already
   uses; no new detection logic needed for this step, just wiring.

2. **Turn the one-off predicates into a lookup, not a growing if/else.**
   As soon as a second board or codec is added, `is_target_codec`-style
   single-hardware predicates stop scaling. Replace them with small
   per-quirk profile files (e.g. `quirks/g615jmr.sh`, one per
   board+codec+keyboard combination) that each declare their own match
   condition and which fix parameters apply (codec SSID, zone count,
   keyboard USB ID, measured idle-power numbers). `lib/hardware-detect.sh`
   stays the fingerprinting layer; a new `lib/quirks.sh` would load and
   match profiles against the fingerprint, closer to how the kernel's own
   HDA quirk tables or `fwupd`'s device quirks work.

3. **Split generic advice from hardware-specific payloads.** Some of what's
   here is really generic Linux-laptop-power knowledge wearing this
   machine's numbers (VMD detection, s2idle-vs-S3 detection, the
   diagnostics-that-lie list in the README). That part could apply broadly
   today with no quirk system at all. The amp/codec/keyboard-specific
   payloads are what actually need the quirk-registry from step 2.

4. **Accept community-contributed profiles.** The README's Contributing
   section already invites reports from other G615-series owners. Once
   step 2 exists, "open a PR with your board's profile file" becomes a
   concrete, low-effort ask instead of "fork the whole repo."

Do not attempt to jump straight to a fully generic multi-brand tool in one
change: the value of this repo today is depth on one machine, and a
half-built generalization (detection without gated apply, or a quirk schema
nothing populates but the original board) is worse than either extreme.
Land step 1 before step 2; land step 2 before inventing a schema for
hardware nobody has contributed data for yet.

## Updates made in this session

- 2026-08-24: Reviewed the repo and added this CLAUDE.md.
- 2026-08-24: Added `lib/hardware-detect.sh` (board/CPU/GPU/codec/amp/
  keyboard detection, no hardcoded usernames/paths/indices). Rewrote
  `check.sh` to fingerprint the machine and gate every fix-specific check
  behind hardware match, adding an N/A outcome that doesn't affect the exit
  code. Updated `install.sh`'s `preflight()` to use the same library and
  warn about amp/keyboard mismatch, not just board mismatch. Updated
  README's repo-layout section to match. `install.sh`'s apply logic itself
  is not yet hardware-gated, see "Generalizing to other hardware" above.
- 2026-08-24: Adopted a no-em-dash rule for comments, commits, and docs
  (see Conventions above), and removed the em dashes this file had
  accumulated earlier in the same session.
