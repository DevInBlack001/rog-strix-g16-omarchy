# Keyboard: RGB zones and the Super key

Two unrelated things, both of which look like software bugs and aren't.

---

## The keyboard is 4-zone RGB, not per-key

Established by running a firmware effect and *looking at it*:

```sh
asusctl aura effect rainbow-wave --direction right --speed med
```

The wave breaks into distinct blocks rather than shading key to key. Do this
test before promising anyone a single-key colour — it costs one command.

**Zone 1 is the leftmost vertical band**: QWER + ASDF, along with Esc, Tab,
Caps, LShift, LCtrl, 1–5 and ZXCV. That band is the finest grain available on
this machine.

### asusd's device table is wrong for this board

`/usr/share/asusd/aura_support.ron` has **no `G615JMR` entry**, so the board
name prefix-matches `G615JM` — which ships `basic_zones: []`. With no zones
declared, asusd refuses every zoned effect:

```
Error: org.freedesktop.DBus.Error.NotSupported: The Aura effect is not supported:
AuraEffect { mode: Static, zone: Key1, ... }
```

The sibling `G615LR` entry, on the same chassis, declares
`[Key1, Key2, Key3, Key4]`. That's what makes this a database gap rather than a
hardware limit.

**Fix:** rewrite `G615JM`'s `basic_zones` to the same four and restart asusd.
`SupportedBasicZones` on `/xyz/ljones/aura/19b6_2_4` then reads `au 4 1 2 3 4`,
and this works per band:

```sh
asusctl aura effect static -c ff0066 --zone 1
```

### Why it needs a pacman hook

asusd reads **only** `/usr/share/asusd/aura_support.ron` — verified against the
binary's strings. There is no `/etc/asusd` override for it. So the edit lands in
a packaged file, and any `asusctl` upgrade (including via `omarchy update`)
reverts it **silently**.

This repo installs:

- `/usr/local/bin/asusd-aura-zones` — idempotent Python patcher. It recognises
  an upstream fix instead of clobbering it, and *warns rather than failing the
  transaction* if the entry disappears.
- `/etc/pacman.d/hooks/zz-asusd-aura-zones.hook` — fires it on asusctl
  Install/Upgrade.

Simulated an upgrade to confirm it re-patches.

**Zone colours themselves need no re-applying.** asusd persists them to
`/etc/asusd/aura_19b6.ron` (`multizone_on: true`) and restores them at boot —
unlike the ALSA gains in [audio.md](audio.md).

### If upstream renames the entry

The patcher prints to stderr and exits 0 rather than breaking your upgrade.
`check.sh` will report `no G615JM entry`. At that point check whether upstream
added a real `G615JMR` entry with proper zones — if so, this fix is obsolete and
you can drop the hook.

---

## The Super key can be disabled in firmware

**Symptom:** Super stops working, survives reboots, and looks exactly like a
broken Hyprland config.

**Cause:** a firmware-level Windows-key lock toggled by **Fn+Super**, held in
the N-KEY keyboard MCU.

**Fix:** press **Fn+Super**. It took *two* presses, not one.

### Why nothing on the Linux side can see or fix it

When engaged, the key produces **no evdev event at all**. A raw read of
`/dev/input/event*` sees every other key on `ASUSTek Computer Inc. N-KEY Device`
but never keycode 125/126. And there's no software toggle to reach for:
`asusctl armoury list` and the `xyz.ljones.Asusd` D-Bus tree expose no win-key
attribute.

Clearing it is equally persistent — after two presses, Super still worked
following a full reboot. **So a Super key that's dead again after a reboot means
the toggle got hit again, not that the fix didn't stick.**

### Confirm it before touching `~/.config/hypr/`

Read evdev directly and watch for keycode 125 (you need to be in the `input`
group; no root required):

```python
# struct 'llHHi' per event; type == 1 is EV_KEY
import os, struct
fd = os.open('/dev/input/event4', os.O_RDONLY)   # your N-KEY device
while True:
    _, _, typ, code, val = struct.unpack('llHHi', os.read(fd, struct.calcsize('llHHi')))
    if typ == 1:
        print(code, val)
```

If `hyprctl configerrors` is clean, you're in the `default` submap, and the
Super binds are present (`hyprctl binds | grep -c 'modmask: 64'`), the config is
fine and the fault is the firmware lock.

### Two dead ends worth skipping

- **`wtype` cannot test this.** Hyprland doesn't fire keybinds from
  virtual-keyboard input — a synthetic bind with *no* modifier fails too, so a
  negative result proves nothing.
- **`hyprctl keyword` is rejected on a Lua config** ("can't work with
  non-legacy parsers"). Use
  `hyprctl eval "hl.bind('SUPER + F12', hl.dsp.exec_cmd('...'))"` instead.

---

## Note on privileges

This machine has **no passwordless sudo**. Scripted privileged commands need
`pkexec`, which raises a polkit dialog on the desktop. `install.sh` uses plain
`sudo` on the assumption a human is running it interactively.
