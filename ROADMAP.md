# Roadmap

This repo works for one laptop today: the ASUS ROG Strix G16 (G615JMR).
Most of what's here can't generalize, a fix keyed to this exact codec's
node addresses or this exact board's device table doesn't help someone on
a Dell or a different ASUS board. What can generalize is the scaffolding
around those fixes: detecting hardware, gating fixes on whether they apply,
and reporting honestly when they don't. This file tracks that, staged, so
the plan doesn't get built out of order.

## Guiding constraint

Chase "safe to run on any laptop, useful on the ones it recognizes," not
"works on any laptop." A fix nobody has measured on the hardware it claims
to help is worse than no fix. See `CLAUDE.md` for the fuller reasoning
behind gating on the narrowest verified signal rather than the broadest
plausible one.

## Phase 0: Detect hardware, gate reporting (done)

Landed in PR #1. `lib/hardware-detect.sh` fingerprints board, CPU vendor,
GPU vendor, audio codec, amp, and keyboard. `check.sh` gates every
fix-specific check behind the matching predicate, reporting `N/A` instead
of a false `FAIL` on hardware that doesn't match. Verified against an
unrelated HP laptop: reports `N/A` across the board, exits 0. See
[docs/hardware-detection.md](docs/hardware-detection.md).

Left undone on purpose: `install.sh`'s apply logic isn't gated the same
way yet, only its preflight warnings are. That's Phase 1.

## Phase 1: Gate `install.sh`, not just `check.sh`

**Status: not started.**

`do_audio`, `do_sleep`, `do_keyboard`, and the rest should check the
matching `is_*`/`has_*` predicate from `lib/hardware-detect.sh` before
writing anything hardware-specific, the same way `check.sh` already
reports `N/A` instead of running a check that doesn't apply. No new
detection logic is needed, this is wiring the library that already exists
into the apply path instead of only the report path.

Exit criteria: running `./install.sh` unmodified on a non-G615 machine is
a safe no-op for the hardware-specific sections (or only touches the
genuinely generic ones, see Phase 3), not a script that writes irrelevant
config and reports it as applied.

## Phase 2: A quirk registry instead of a growing if/else

**Status: not started, blocked on a second real hardware profile existing.**

`is_target_codec`, `is_target_amp`, and `is_g615_board` are single-hardware
predicates baked directly into `lib/hardware-detect.sh`. That's fine for
one board. It stops scaling the moment a second one shows up. Replace them
with small per-quirk profile files, one per board+codec+keyboard
combination, e.g. `quirks/g615jmr.sh` as the first entry, each declaring
its own match condition and the fix parameters that go with it (codec
SSID, zone count, keyboard USB ID, measured idle-power numbers).

`lib/hardware-detect.sh` stays the fingerprinting layer, facts about the
machine. A new `lib/quirks.sh` becomes the matching layer, which profile
(if any) matches those facts. This is roughly what the Linux kernel's own
HDA quirk tables and `fwupd`'s device quirks already do, at a scale this
repo doesn't need yet.

Exit criteria: a second board's profile can be added as a new file without
touching the predicates the first board depends on.

## Phase 3: Split generic advice from hardware-specific payloads

**Status: not started.**

Some of what's here is general Linux-laptop-power knowledge wearing this
machine's numbers: VMD detection, s2idle-vs-S3 detection logic, the
"diagnostics that lie on this hardware" list in the README. That part
already applies broadly (VMD and NVIDIA gating are vendor-level, not
board-level, as of Phase 0) and needs no quirk system at all. The amp,
codec, and keyboard-specific payloads are what actually need the Phase 2
registry.

Exit criteria: the README's "What gets fixed" table can honestly mark
which rows apply broadly and which need your exact board.

## Phase 4: Accept community-contributed profiles

**Status: not started, blocked on Phase 2.**

The README's Contributing section already invites reports from other
G615-series owners, and, since Phase 0, from owners of unrelated hardware
entirely, the fingerprint `check.sh` prints is exactly the input a new
profile needs. Once Phase 2 exists, contributing support for a new board
becomes: run `./check.sh`, paste the fingerprint into an issue or a new
`quirks/<board>.sh`, open a PR. No forking the whole repo's assumptions
required.

Exit criteria: at least one profile in `quirks/` for hardware the original
author doesn't own.

## Explicit non-goals, for now

- **A GUI, package, or installer that auto-detects "your" fix.** This
  repo stays scripts plus docs, not a product.
- **Fixes for hardware nobody has measured.** A profile that guesses at
  numbers (idle watts, zone counts, timing) is worse than no profile.
- **Skipping ahead.** Land Phase 1 before Phase 2. Land Phase 2 before
  inventing a schema for hardware nobody has contributed data for yet. A
  half-built generalization, detection without gated apply, or a quirk
  schema nothing populates but the original board, is worse than either
  extreme.

## How to help right now

- **Own a G615-series board that behaves differently?** Open an issue
  with `./check.sh` output, see the README's Contributing section.
- **Own different hardware entirely?** Same ask: `./check.sh` output plus
  your board/codec/keyboard identifiers is exactly what Phase 2 needs,
  even though there's nowhere to plug it in yet.
- **Want to pick up Phase 1?** It's scoped, self-contained, and doesn't
  need you to own any particular hardware to implement, only to review.

This file is the public plan. `CLAUDE.md`'s "Generalizing to other
hardware and brands" section is the shorter, agent-facing pointer to it,
keep the two in sync rather than letting the plan drift between them.
