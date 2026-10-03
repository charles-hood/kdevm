# kdevm runbook

Measured facts, provenance, fallbacks taken, gotchas. Dates are when the
fact was established on the M4 Pro.

## Provenance

| component | value |
|---|---|
| try-omarchy commit | 82927e98078a452ace33e527a328ef0b12a0af07 (main, 2026-10-03 UTC) |
| QEMU | 11.1.1, gitlab commit c3d48b7d1e89604920e5b81b91140c2ad39a1943, 23 patches (`docs/patches.md`) |
| virglrenderer | 1.3.0 source + startergo tap 1.0.42 patch set, built debugoptimized |
| libslirp | 4.9.4 source + 2 patches (ICMP matching, IPv4 UDP translation) |
| ANGLE / libepoxy | startergo bottles 1.0.16 / 1.0.5 (arm64_sequoia) |
| meson / ninja | 1.9.0 / 1.13.0 (pinned downloads, not Homebrew) |
| host | Apple M4 Pro, 14 cores, 48 GB, macOS 27.0.1 (26A434), Xcode 26 / Swift 6.4 |
| UEFI firmware | Homebrew qemu 11.1.1's `edk2-aarch64-code.fd` + a private copy of `edk2-arm-vars.fd` per VM |
| Debian base | `debian-13-generic-arm64.qcow2` from cloud.debian.org trixie/latest; SHA512 in `~/.cache/kdevm/factory-info.txt` |
| guest kernel / Mesa / KWin / Plasma | recorded in `~/.cache/kdevm/factory-info.txt` by `guest/build.sh` |

## Phase 0: runtime (2026-10-02)

- `runtime/build.sh` ran try-omarchy's `macos/build-qemu-gpu-runtime.sh`
  unchanged. Wall time **96 s** for QEMU + VirGL + libslirp (14 cores, default
  parallelism), **21 s** for `swift build -c release` of the helper. The plan
  budgeted 30+ minutes; the pinned-source build is small because QEMU is
  configured for one target with few device models.
- Staged runtime: `bin/qemu-system-aarch64`, `bin/omarchy-vm-helper`,
  `bin/zstd`, 17 dylibs in `lib/`. No `share/qemu`: firmware comes from the
  Homebrew package.
- Signature: ad-hoc, with `com.apple.security.hypervisor`. Consequence: macOS
  privacy grants (Microphone, Accessibility) are per binary identity and
  re-prompt after a runtime rebuild.
- Smoke: `virtio-gpu-gl-pci`, `virtio-pinch-pci`, `virtio-9p-pci`,
  `virtio-balloon-pci`, `intel-hda`, `hda-micro` present; `-display
  cocoa,gl=on` parses; audio drivers `none sdl wav`; helper answers
  `--host-timezone` (America/New_York) and `--host-audio-frequency output|input`
  (48000 / 48000) outside an app bundle.

## Rules that are easy to forget

- `gic-version=3` is mandatory under HVF on this QEMU; it rejects GICv2.
- Never attach the Homebrew `edk2-arm-vars.fd` writable. Every kdevm boot
  (provisioning, preflight, up) uses its own copy.
- The `generic` Debian image, not `genericcloud`: the cloud kernel lacks
  virtio_gpu, snd_hda_intel and friends. `guest/build.sh` fails the factory
  if any required module or CONFIG is missing.
- NOPASSWD sudo in the guest is a temporary convenience (same as the
  container). It bypasses PAM and must go if Touch ID sudo is ever wired in.
- Per-launch hints reach the guest through QEMU `fw_cfg`
  (`/sys/firmware/qemu_fw_cfg/by_name/opt/kdevm/`), not kernel arguments,
  because the guest boots through UEFI and grub.

## Phase 1: factory

Gotchas met on the way (2026-10-02):

- The runtime has no `share/qemu`, so any PCI device whose class defaults an
  option ROM (`virtio-net-pci` wants `efi-virtio.rom`) fails at start with
  "failed to find romfile". try-omarchy's launcher puts `romfile=` on every
  PCI device; kdevm does the same. UEFI boots from disk, nothing needs a ROM.
- `guest/build.sh` refuses to boot if any `@@` token survives rendering. The
  first run tripped on the template's own header comment, which named the
  token syntax. Rendering is done by Python with literal replacement, not
  sed, so a password containing `&` or `|` cannot corrupt the YAML.
- The provisioning boot under HVF reaches the initramfs in well under a
  second of guest time and answers ssh 16 s after launch; GROWROOT extends
  `/dev/vda1` to the 40 GB disk on the first boot (cloud-init growpart).
- cloud-init `users: groups:` must name only groups that exist in the image.
  `netdev` did not, cloud-init created it as a regular group, and
  NetworkManager's postinst (pulled in by plasma-nm) aborted with "The group
  `netdev' already exists and is not a system group" (exit 13), which failed
  the whole apt transaction. Groups are now `sudo render video audio users`.
- The first full run installed Recommends (fonts-noto-cjk, libvlc, sshfs,
  vulkan-tools...). Switched to `APT::Install-Recommends "false"` like the
  container, with the wanted Recommends listed explicitly (qt6-wayland,
  dbus-user-session, kio-extras, xdg-desktop-portal-kde, polkit-kde-agent-1,
  kde-spectacle).
- `cloud-init status --wait` exits 2 for "degraded" (done, with warnings),
  which the script first read as failure. The one warning was `lock_passwd:
  false` without a password in the `users:` entry (the password came from a
  separate `chpasswd:` block); `plain_text_passwd` in the entry fixes it.
- The kernel checks first reported every module absent on a VM that was
  plainly running on virtio-blk and virtio-net: a non-root ssh session's
  PATH on Debian 13 has no `/usr/sbin`, so `modinfo` was not found and the
  fallback accepted only `=y`. The check now calls `/usr/sbin/modinfo -k`
  against the newest installed kernel (package_upgrade may install one the
  factory boots next) and accepts `=m` or `=y` from `/boot/config-*`.
- With no Recommends the whole cloud-init run (apt update, dist-upgrade,
  Plasma, both browsers) takes about **95 s** of guest time.
- On a cloud-init failure `guest/build.sh` now copies the whole
  `cloud-init-output.log` to `~/.cache/kdevm/`, prints the apt and dpkg error
  lines, and keeps the half-built disk as `factory.qcow2.failed`.

(results pending)

## Phase 1.5: graphics preflight

(pending)

## Phase 2: the window

(pending)

## Phase 3: browsers, sound, mic

(pending)

## Phase 4: clipboard and shared folder

(pending)

## Measurements

(pending)
