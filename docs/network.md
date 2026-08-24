# Wi-Fi: bar icon shows disconnected on a working link

Not machine-specific, this hits any Omarchy install with an NM profile written
by a third-party installer. Included because it wasted an afternoon and the
symptom points nowhere near the cause.

## Symptom

The Omarchy bar renders the 󰤮 no-connection icon while the link works perfectly.
`nmcli`, `ping`, DNS, everything is healthy.

## Cause

The profile, created by the [eduroam CAT
installer](https://cat.eduroam.org/), CA cert at
`~/.config/cat_installer/ca.pem`, had **no `802-11-wireless.mode` key at all**.

NetworkManager treats a missing mode as infrastructure. Quickshell's
`Quickshell.Networking` NM backend (quickshell-git 0.3.0.r20, shipped by Omarchy
4.0.0) does not: it refuses to associate such a profile with a scanned network.
So `WifiNetwork.nmSettings` stayed `[]`, `known`/`connected` stayed false, and
`omarchy.network` in the bar drew the disconnected icon.

## Fix

```sh
nmcli connection modify eduroam 802-11-wireless.mode infrastructure
omarchy restart shell
```

## If it regresses

Re-running the CAT installer recreates the profile **without** the mode key.
Check first:

```sh
nmcli -g 802-11-wireless.mode connection show <profile>
```

Empty output means you've hit this again.

## Why the usual diagnostics tell you nothing

The bar icon is derived purely from Quickshell's NM object model (`Panel.qml`
`kind` → `connectedWifiNetwork`), **not** from `omarchy-network-status`. So
`nmcli`/`ping` all looking healthy is expected and proves nothing about the
icon.

To reproduce or diagnose properly, run a throwaway Quickshell config that prints
`Networking.devices` → wifi device → `networks[].{name, connected, known, nmSettings}`.
Note the device list takes ~3 s to populate, and non-connected networks only
appear while `scannerEnabled` is true.
