# Vendored from try-omarchy (MIT), commit 82927e98078a452ace33e527a328ef0b12a0af07

Verbatim copies of guest-side files from `guest/native-overlay/` in
https://github.com/omacom/try-omarchy. They are distro-neutral (Python over
wl-clipboard, a udev rule, a systemd user unit, a PipeWire drop-in) and are
installed into the Debian factory by cloud-init. Do not edit here; bump the
pin in `runtime/pin.txt` and re-copy.

| file | upstream path |
|---|---|
| omarchy-native-clipboard-bridge | usr/local/bin/omarchy-native-clipboard-bridge |
| omarchy-native-clipboard-bridge.service | usr/lib/systemd/user/omarchy-native-clipboard-bridge.service |
| 92-omarchy-native-clipboard.rules | etc/udev/rules.d/92-omarchy-native-clipboard.rules |
| 90-try-omarchy-quantum.conf | usr/share/pipewire/pipewire.conf.d/90-try-omarchy-quantum.conf |
