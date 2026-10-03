# Vendored from try-omarchy (MIT), commit 82927e98078a452ace33e527a328ef0b12a0af07

Verbatim copies of guest-side files from `guest/native-overlay/` in
https://github.com/omacom/try-omarchy. They are distro-neutral (Python over
wl-clipboard, a udev rule, a systemd user unit, a PipeWire drop-in) and are
installed into the Debian factory by cloud-init. Do not edit here; bump the
pin in `runtime/pin.txt` and re-copy.

The battery kernel module (`try-omarchy-battery/`, built in the guest by
DKMS) is GPL-2.0-only, as its SPDX header says and as a module that
registers power supplies has to be; the licence text is beside it. Every
other file here is MIT (`LICENSE.try-omarchy`).

| file | upstream path |
|---|---|
| omarchy-native-clipboard-bridge | usr/local/bin/omarchy-native-clipboard-bridge |
| omarchy-native-clipboard-bridge.service | usr/lib/systemd/user/omarchy-native-clipboard-bridge.service |
| 92-omarchy-native-clipboard.rules | etc/udev/rules.d/92-omarchy-native-clipboard.rules |
| 90-try-omarchy-quantum.conf | usr/share/pipewire/pipewire.conf.d/90-try-omarchy-quantum.conf |
| omarchy-native-battery-bridge | usr/local/bin/omarchy-native-battery-bridge |
| omarchy-native-battery-bridge.service | usr/lib/systemd/system/omarchy-native-battery-bridge.service |
| 95-omarchy-native-battery.rules | etc/udev/rules.d/95-omarchy-native-battery.rules |
| 95-try-omarchy-battery.conf | etc/modules-load.d/95-try-omarchy-battery.conf |
| try-omarchy-battery/{try-omarchy-battery.c,Makefile,dkms.conf} | ../native-module/try-omarchy-battery/ (beside native-overlay) |
