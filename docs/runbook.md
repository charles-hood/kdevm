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

(pending)

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
