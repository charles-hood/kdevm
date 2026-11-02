# Vendored from try-omarchy (MIT), commit 13d63df8da2947f833c04025ff5ade187d39ba81 (v1.3.0)

Verbatim copies of guest-side files from `guest/package/try-omarchy/` in
https://github.com/omacom/try-omarchy (their Arch package; before v1.0.0
the same files lived under `guest/native-overlay/`). They are distro-neutral
(Python over wl-clipboard, udev rules, systemd units, a PipeWire drop-in)
and are installed into the Debian factory by cloud-init, at the paths their
unit files name (`/usr/bin` for the bridges). Do not edit here; bump the pin
in `runtime/pin.txt` and re-copy.

The battery kernel module (`try-omarchy-battery/`, built in the guest by
DKMS) is GPL-2.0-only, as its SPDX header says and as a module that
registers power supplies has to be; the licence text is beside it. Every
other file here is MIT (`LICENSE.try-omarchy`).

| file | upstream path under guest/package/try-omarchy/ |
|---|---|
| omarchy-native-clipboard-bridge | files/usr/bin/omarchy-native-clipboard-bridge |
| omarchy-native-clipboard-bridge.service | files/usr/lib/systemd/user/omarchy-native-clipboard-bridge.service |
| 70-try-omarchy-clipboard.rules | files/usr/lib/udev/rules.d/70-try-omarchy-clipboard.rules |
| 90-try-omarchy-quantum.conf | files/usr/share/pipewire/pipewire.conf.d/90-try-omarchy-quantum.conf |
| omarchy-native-battery-bridge | files/usr/bin/omarchy-native-battery-bridge |
| omarchy-native-battery-bridge.service | files/usr/lib/systemd/system/omarchy-native-battery-bridge.service |
| 70-try-omarchy-battery.rules | files/usr/lib/udev/rules.d/70-try-omarchy-battery.rules |
| 95-try-omarchy-battery.conf | files/usr/lib/modules-load.d/95-try-omarchy-battery.conf |
| try-omarchy-battery/{try-omarchy-battery.c,Makefile,dkms.conf} | battery/ |
