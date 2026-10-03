# kdevm runbook

Measured facts, provenance, fallbacks taken, gotchas. Dates are when the
fact was established on the M4 Pro.

Paths: this runbook records the author's machine, where the runtime lives in
`~/Artifacts/kdevm-runtime/` and the guest user is `charles`. Since the
release hygiene pass (2026-10-02) the defaults are
`~/.local/share/kdevm/runtime` and the host login name, with the author's
values kept in `~/.config/kdevm/env`.

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

## Branding (2026-10-02 22:43)

The application menu read "About Try Omarchy / Hide Try Omarchy / Quit Try
Omarchy" and the quit alert named it too: the Cocoa product-identity patch
hard-codes the strings and sets the process name. `runtime/build.sh` now
rewrites that one patch to say "kdevm" after checkout and pins the new
SHA-256 into their build script (which verifies every patch hash); nothing
else in their tree is touched. Rebuild took 88 s. The helper's own log line
("The Mac clipboard is shared with Omarchy") is left alone. The window title
comes from `-name kdevm`. A rebuilt runtime has a new ad-hoc signature, so
macOS re-asks the Microphone permission once.

## 0.1.0 code review (Codex, 2026-10-02, commit 842c2fe)

Seven findings, six rated release blockers, all confirmed and fixed; the
probes are kept in `tests/checks.sh`.

| # | finding | fix | validated by |
|---|---|---|---|
| 1 | `tr -dc ... < /dev/urandom \| head -c 20` exits 141 under pipefail, so a fresh install never created the password | Python `secrets`, no pipeline | isolated config: 20 chars, mode 600, reused on rerun |
| 2 | `pkg-config` missing from the documented prerequisites; their build script requires it and Homebrew's qemu bottle does not leave it | `brew install qemu cdrtools pkgconf` | formula exists, 3.0.7 |
| 3 | `factory --force` replaced the backing image under a live overlay | refuse while `work.qcow2` exists; `rebuild` drops it first | seeded empty overlay: refused before any write |
| 4 | a saved pid was trusted on `kill -0` alone, so a reused pid could be killed | pid counts only if `ps` shows our QEMU on our overlay; bridge pid must show kdevm | sleeper pid in both files survived `down` and `status` |
| 5 | no lock: two `up`s or an `up`/`destroy` pair could orphan a VM | `mkdir` lock per state dir across every verb and the factory build, dead holder reclaimed | live holder blocked; dead holder reclaimed; lock released |
| 6 | state dir 0755, disks 0644, seed with the plaintext password kept on failure | `umask 077` first thing in both scripts, state 0700, disks and vars 0600, seed removed on every exit | audit after the rebuild (below) |
| 7 | password inserted into YAML unquoted: `&secret` became null, `12345678` an integer | JSON-encode password and key (valid double-quoted scalars) | 13 hostile values parsed back identical by PyYAML |

Audit after `destroy --all`, `factory`, `up` on the fixed scripts (23:05):
`~/.cache/kdevm` 700, `run/` 700, `factory.qcow2`, `work.qcow2`,
`efivars.fd` and the base image 600, sockets 700, no seed, lock, building
or failed leftovers; factory 117 s; the baked `kdevm-hints.service` applied
scale 2 on the first boot; clipboard and share round trips pass;
`tests/checks.sh` all green.

Found while validating: the config file `~/.config/kdevm/env` was sourced
after the environment and overrode explicit variables. It is now read line
by line and only fills variables that are unset.

### Second pass (Codex, commit b650ac3): 4 fixed, 2 partial, 1 not fixed, 3 new

| item | what was wrong | fix | validated by |
|---|---|---|---|
| 5 lock | the EXIT trap was set inside `take_lock()`; zsh runs a function-scoped trap when the function returns, so the lock vanished before the operation; stale takeover was not exclusive | script-scope `trap kdevm_exit EXIT`; dead holder taken over by `mv` (only one contender's rename succeeds); guest/build.sh takes the lock before its guards | `_lockprobe` verb: lock present during the hold, two overlapping probes serialise, two contenders against a dead holder produce exactly one holder |
| 4 bridge pid | any process whose command mentioned "kdevm" was accepted | supervisor is its own zsh process named via `ARGV0="kdevm-bridge-supervisor <qemu pid>"`; both pid files store "pid start-time"; a pid counts only with the right command shape AND the recorded start time | an `ARGV0="vim /review/kdevm.sh"` sleeper survives `down`; a genuine supervisor identity is stopped |
| 7 non-BMP | `json.dumps` emitted `\ud83d\udd11` surrogates, which PyYAML returns as two surrogate chars | `ensure_ascii=False` (raw UTF-8 is valid in a YAML double-quoted scalar) | `pass🔑word` round-trips |
| config loader | only `KDEVM_*` keys read; an explicit empty variable treated as unset | any `NAME=value` line; `${(P)k+set}` distinguishes set from empty | loader probe: `QEMU_IMG` kept, `KDEVM_USER=` kept empty |
| test isolation | builder probes could touch the real password file; `py_compile` wrote a `.pyc` into the tree (and it was committed) | fixtures for password and key on every builder call; compile in memory; `.pyc` untracked and ignored | tree clean after a run |
| cleanup under set -e | a failed `kill` in the trap aborted the rest of it | one `cleanup()` with `set +e`, every step non-fatal | reviewed; same function covers success and failure |

Found while validating, by breaking it live: `ps -o lstart=` pads with
trailing spaces, so the first start-time comparison failed, `status`
disowned the running QEMU, `down` did nothing, and a second `up` launched
another QEMU on the same overlay. QEMU's own image lock refused it ("Failed
to get write lock"), so nothing was corrupted, but `up` still reported
success because the sockets appear before the disk is opened. Three fixes:
whitespace is collapsed on both sides of the comparison; `up` requires the
process alive and QMP answering after the socket wait; `up` refuses to
start when any untracked QEMU holds the overlay. Then: `down` (ssh path,
since the first QEMU's QMP socket had been unlinked), supervisor gone,
`up`, QMP answering, a duplicate `up` refused, one QEMU process.

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
  sed; since the 0.1.0 review the password and the ssh key are inserted as
  JSON strings (valid YAML double-quoted scalars), so `&`, `|`, `#`, quotes
  and all-digit passwords survive intact. Plain literal insertion did not:
  a reviewer showed `&secret` parsing to null and `12345678` to an integer.
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

Result (2026-10-02, seven runs in): `factory.qcow2` 3.9 GB on disk, **108 to
114 s** end to end (ssh at 16 s, cloud-init 95 to 110 s, checks, poweroff).
Kernel 6.12.111+deb13-arm64, Mesa 25.0.7, KWin and Plasma 6.3.6, Chrome
154.0.8037.97, Firefox ESR 153.4.0, sddm 0.21. All twelve kernel checks pass
as modules (virtio_gpu, virtio_input, virtio_blk, virtio_net, virtio-rng,
virtio_balloon, 9p, 9pnet, 9pnet_virtio, snd_hda_intel, qemu_fw_cfg) plus
CONFIG_PAGE_REPORTING=y. Session files: `plasma.desktop` (Wayland),
`plasmax11.desktop` (X11).

## Phase 1.5: graphics preflight

Passed first time (2026-10-02 22:13). `/dev/dri/card0` (video) and
`renderD128` (render) present; `eglinfo -B` on the GBM platform: renderer
**virgl (Apple M4 Pro)**, OpenGL 4.1 core and compatibility, OpenGL ES 3.0,
Mesa 25.0.7; `kmscube -c 300` ran as charles with sddm stopped, no seat-ACL
trouble (charles is in `video` and `render`). Verdict line: GPU stack OK.
Gotcha: the preflight pipeline (`tee`) hung after the verdict because the
clipboard-bridge supervisor subshell had inherited stdout; its stdio is now
detached.

## Phase 2: the window

Rung 1 of the ladder held; no fallback was needed (2026-10-02 22:16 to 22:26).

- sddm autologin lands in **Plasma Wayland** (seat0 session type `wayland`).
  KWin support information: compositing active, type OpenGL, renderer
  **virgl (Apple M4 Pro)**, GL 4.1 core, platform EGL.
- **Live resize works natively.** The Cocoa dynamic-display patch publishes
  the window's backing-pixel size in the EDID; resizing the Mac window with
  System Events changed `card0-Virtual-1` from 1900x1070 to 2188x1232 and
  KScreen followed on its own. No `kdevm-display-sync` helper written.
- **Backing pixels, so scale 2.** The M32UC is a 4K panel run at 1920x1080
  points (ratio 2) and its `system_profiler` entry never says "Retina";
  the first heuristic (grep Retina) said 1. `scale_hint` now divides
  `_spdisplays_pixels` by `_spdisplays_resolution`. KScreen does NOT pick
  scale 2 by itself from this EDID, so the hint is needed; the first-login
  hook applied it (`kscreen-doctor output.Virtual-1.scale.2`, geometry
  492x277 at scale 2 for a 984x554 mode).
- **fw_cfg is root-only in sysfs** (`raw` is 0400), so the user-level
  first-login hook saw an empty hint. `kdevm-hints.service` (root, oneshot,
  before the display manager) copies `opt/kdevm/*` to `/run/kdevm/` 0644.
- The first window opened at 950x567 points on one run and 492x277 on the
  next; Cocoa sizes the initial window from the initial virtio-gpu mode in
  points. `up` now sets `xres/yres` to the main display's pixel size so the
  window opens near full size and zoom-to-fit keeps it on screen.
- Window title: `-name kdevm` (the product-identity patch shows the bundle
  name only inside an .app; outside it the title was "QEMU").
- **Idle QEMU CPU: 7.5% of one core mean, 5.4% median** over 30 s with
  try-omarchy's `profile-process.py` (QMP state checked throughout), 0.54%
  of the 14-core host; whole-system busy 14% including everything else.
  Charged footprint 3.75 to 3.80 GB for an 8 GB guest that reported 883 MB
  used and 1 GB cache. try-omarchy's own idle figure is 10 to 15%.
- Audio: `wpctl status` shows the HDA device as "Built-in Audio" with one
  sink and one source (the hda-micro codec).
- `down`: QMP `system_powerdown` does nothing useful under Plasma (its power
  manager owns the ACPI button); `down` now runs `sudo systemctl poweroff`
  over ssh first, QMP second, kill after 45 s.

## Phase 3: browsers, sound, mic

Pre-checks from ssh (2026-10-02 22:31), before Charles's ten minutes:

- Microphone: `pw-record --rate 48000 --channels 1` for 3.6 s produced a
  352 KB WAV through the hda-micro codec (signal level in the next line of
  the log). The first use triggered macOS's Microphone prompt for the QEMU
  binary.
- PipeWire sees `alsa_output.pci-0000_00_06.0.analog-stereo` (sink) and
  `alsa_input...` (source), both 48 kHz s16le.
- Chrome from ssh needs `--ozone-platform=wayland` with `DISPLAY` unset; an
  exported `DISPLAY` made ozone pick X11 and fail ("Missing X server").
  Google's Debian wrapper does not read `~/.config/chrome-flags.conf` (that
  is Arch's); the panel launcher goes through the .desktop entry, so Wayland
  for Chrome is selected by `ELECTRON_OZONE_PLATFORM_HINT`/`--ozone-platform-hint=auto`
  only if Chrome honours it; `chrome://gpu` says which.

Charles, chrome://gpu, 2026-10-02 22:35: **Chrome graphics pass.** Native
Wayland confirmed; hardware compositing, rasterization and WebGL all active
on VirGL / Apple M4 Pro; zero GPU-process crashes. Hardware video decode is
not available (VA-API initialisation fails, `vaInitialize failed: unknown
libva error`), which is the architecture's known limit: video decodes on the
CPU, and smooth 1080p playback is the acceptance bar, not hardware decode.
No Chrome GPU fallback flag was needed.

Charles, 2026-10-02 22:50: **"mic works, youtube with sound works too."**
Milestone 3 met on the three things that could have failed (GPU, sound
out, mic in). Not separately reported yet: pinch, Firefox.

## Phase 4: clipboard and shared folder

- **Shared folder** (virtio-9p, tag `mac`, their `guest_owner_uid/gid`
  patch, our 10-line mount unit at `~/Mac`): mounted at boot; round trip
  passed in both directions for create, edit, rename and delete; guest-made
  files appear on the Mac as charles:staff.
- **Clipboard** (their helper `--bridge-native-clipboard` + their guest
  agent, both unmodified, port name `dev.tryomarchy.clipboard` kept): the
  helper refuses a socket unless it and its parent directory are owned by
  the uid with no group/other bits (`NativeBridgeSocket.swift`), so `up`
  runs QEMU under `umask 077` with the sockets in `~/.cache/kdevm/run/`
  (0700). Text Mac to guest and guest to Mac both pass (guest to Mac
  arrives within 0.5 s). Two earlier reads were masked by Charles copying
  text to another window at that moment: the Mac has one pasteboard, so a
  bridge test needs it left alone for a few seconds.

## Measurements (2026-10-02, M4 Pro, 4 vCPU, 8 GB, Plasma Wayland idle)

| what | value | how |
|---|---|---|
| runtime build | 96 s QEMU+VirGL+slirp, 21 s helper | `runtime/build.sh` |
| factory build | 108 to 114 s (ssh at 16 s, cloud-init 95 to 110 s) | `guest/build.sh` |
| boot to Wayland session | 14 s | `up` to `/run/user/1000/wayland-0` |
| clean power-off | 3 s | `down` (ssh poweroff) |
| idle QEMU CPU | 7.5% of one core mean, 5.4% median (30 s); 5.8 to 7.4% in later 10 s samples | `profile-process.py` with QMP guard |
| idle charged footprint | 3.1 GB (first run 3.75 GB) | same |
| memory reclaim | 3.1 GB idle; 5.1 GB while the guest touched 2 GiB; 3.1 GB again within 25 s of the free | same, three samples |
| live resize | window 950x567 pt to 1400x900 pt: mode 1900x1070 to 2188x1232, KScreen followed unaided | System Events + `kscreen-doctor -o` |
| clipboard guest to Mac | text in under 0.5 s; PNG 154 B arrived; Mac PNG 96 B arrived in guest | `wl-copy`, `pbpaste`, `clipboard info` |

Compared with the container (`desktop-kde-local`): image build 80 s vs
factory 110 s; start 3 s vs 14 s to a logged-in desktop; idle near 0 vs
about 7% of one core; what the VM adds is the GPU, Wayland, a native
window, mic, PNG clipboard and a shared folder.
