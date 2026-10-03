# kdevm

**A Debian 13 + KDE Plasma 6 desktop as a GPU-accelerated VM on Apple Silicon,
in a native Mac window.** QEMU on Apple's Hypervisor.framework, the guest's
OpenGL replayed on the Apple GPU through VirGL, Plasma Wayland with KWin
compositing, HiDPI, live window resize, sound out and microphone in, two-way
clipboard (text and PNG), the Mac's time zone and battery, one shared Mac
folder, ssh.
No RDP client, no greeter, no Linux display driver to install.

The host runtime is [try-omarchy](https://github.com/omacom/try-omarchy)'s
patched QEMU 11.1.1 (23 patches: Cocoa dynamic display, VirGL on native
macOS OpenGL, HVF free-page memory reclaim, HDA audio recovery, precise
trackpad scroll and pinch, 9p ownership mapping, and more), built by their
own script from a pinned commit, plus their Swift helper for the clipboard,
time zone and battery bridges. Everything Omarchy-, Arch- and Hyprland-specific is
left behind. The
guest is an ordinary Debian cloud image provisioned once by cloud-init into
a factory image and run from a throwaway qcow2 overlay, so the VM stays
disposable: factory = image, overlay = container.

Built in one evening on an M4 Pro running macOS 27.0.1 and accepted on
Chrome's own `chrome://gpu` page: native Wayland, hardware compositing,
rasterization and WebGL on `virgl (Apple M4 Pro)`, no GPU-process crashes.

## Numbers (M4 Pro, 4 vCPU, 8 GB, idle Plasma Wayland)

| | |
|---|---|
| Runtime build (QEMU + VirGL + libslirp + helper) | 96 s + 21 s |
| Factory image build (cloud-init, Plasma, both browsers, the battery module) | about 2 minutes (102 to 137 s over seven builds), 4.3 GB on disk |
| Boot to a logged-in desktop | 14 s |
| Clean power-off | 3 s |
| Idle QEMU CPU | about 7% of one core (5.4% median) |
| Charged memory at idle | 3.1 GB; a freed 2 GiB block in the guest came back to macOS within 25 s |
| Live resize | the guest mode follows the window through the virtio-gpu EDID, no helper needed |

Measured with try-omarchy's `profile-process.py`; method and provenance in
[docs/runbook.md](docs/runbook.md). The factory row is current. Every other
row was measured on 0.1.0, before the time zone and battery bridges and the
power applet were added, and has not been measured again.

## Requirements

- Apple Silicon Mac, macOS 15 or newer (built and tested on 27.0.1).
- Xcode or the Command Line Tools (clang, Swift 6, codesign).
- Homebrew `qemu` (for `qemu-img` and the EDK II firmware files),
  `cdrtools` (for `mkisofs`) and `pkgconf` (try-omarchy's runtime build
  needs `pkg-config`, which Homebrew's qemu bottle does not leave behind):

  ```
  brew install qemu cdrtools pkgconf
  ```

  Homebrew's own `qemu-system-aarch64` is not used: it has no GL display and
  no `virtio-gpu-gl` device. kdevm builds its own.
- An ssh key pair (`ssh-keygen -t ed25519` if you have none).
- About 1 GB of downloads on first build (pinned QEMU, VirGL, libslirp,
  Homebrew bottles, the Debian cloud image, Google Chrome) and about 6 GB of
  disk for the runtime, base image and factory.

## Quick start

```
git clone https://github.com/charles-hood/kdevm.git ~/Projects/kdevm
cd ~/Projects/kdevm
./kdevm.sh up
```

`up` builds whatever is missing: the runtime (about two minutes), then the
factory image (about two minutes, a headless VM running cloud-init), then
opens the window. Plasma logs in by itself. The first microphone use
triggers a macOS permission prompt for the VM's binary, `kdevm`.

Run `./kdevm.sh preflight` instead of `up` the first time if you want the
graphics stack checked before Plasma touches it: it stops the display
manager over ssh, runs `eglinfo` and `kmscube`, prints a verdict that names
the layer at fault if anything is wrong, and starts the desktop.

## Upgrading

Stop the VM first, with the version that started it: `./kdevm.sh down`, then
update the checkout. A VM left running across an update may not be
recognised by the new scripts; they will refuse to touch its disk, and it
then has to be powered off from inside the guest.

After an update, `./kdevm.sh up` rebuilds the runtime by itself when the
update needs a new one (about two minutes; macOS may ask for the microphone
again). The factory image is never rebuilt automatically: run
`./kdevm.sh rebuild` to get guest-side changes (it replaces the overlay).
[CHANGELOG.md](CHANGELOG.md) says which releases need which.

## Verbs

```
kdevm.sh runtime     build/stage the QEMU runtime + helper (--force to rebuild)
kdevm.sh factory     build the Debian factory image
kdevm.sh up          start the desktop (builds anything missing)
kdevm.sh launch      same as up
kdevm.sh preflight   up + graphics preflight over ssh, prints a verdict
kdevm.sh down        clean power-off (overlay state kept; up resumes it)
kdevm.sh destroy     drop the overlay (--all: factory and base image too)
kdevm.sh rebuild     new factory (fresh packages, fresh Chrome), new overlay
kdevm.sh status      the first diagnostic command
kdevm.sh ssh [cmd]   ssh <user>@localhost:2222
kdevm.sh console     tail the guest serial log
```

## Configuration

Environment variables, optionally kept in `~/.config/kdevm/env` (sourced by
every script):

| variable | default | meaning |
|---|---|---|
| `KDEVM_CPUS` | 4 | vCPUs (try-omarchy's documented minimum) |
| `KDEVM_MEM_MB` | 8192 | guest RAM; unused pages are returned to macOS |
| `KDEVM_SCALE` | auto | Plasma scale hint: auto = main display pixels / points, or 1, 2 |
| `KDEVM_WINDOW` | auto | first-window size: auto (display minus margins), keep, or `WxH` points |
| `KDEVM_FULLSCREEN` | off | open full screen |
| `KDEVM_ICON` | `assets/kdevm-icon.png` | the Dock icon: a square PNG (1024x1024 with transparency is ideal), converted on every `up` |
| `KDEVM_TIMEZONE` | mirror | mirror: the guest's time zone follows the Mac's, live (the Mac always wins); off: the guest keeps its own (UTC in a fresh factory) |
| `KDEVM_SHARE` | `~/kdevm-share` | the Mac folder shared with the guest, mounted at `~/Mac` there |
| `KDEVM_USER` | your login name | the guest user |
| `KDEVM_PASS_FILE` | `~/.config/kdevm/password` | the guest user's password (generated if missing) |
| `KDEVM_SSH_PUB` | first of `~/.ssh/id_{ed25519,ecdsa,rsa}.pub` | key installed in the guest |
| `KDEVM_RUNTIME_ROOT` | `~/.local/share/kdevm/runtime` | where built runtimes live, one per pin |
| `KDEVM_STATE` | `~/.cache/kdevm` | base image, factory, overlay, UEFI vars, sockets, logs |
| `KDEVM_DISK_GB` | 40 | sparse guest disk size |

## Where things live

| | |
|---|---|
| the repo | `kdevm.sh`, `lib/kdevm-common.zsh` (kernel lock, process identity, QMP, config), `guest/factory.zsh` (the factory build as a function), the build scripts, the cloud-init template, vendored guest agents, `tests/checks.sh`, docs. Nothing large, nothing secret. |
| `$KDEVM_RUNTIME_ROOT/<pin>/` | built QEMU + helper, `provenance.txt`, `current` symlink. Slow to rebuild, keep it. Beside the pins: `TryOmarchy.icns`, the Dock icon `up` builds (the name is the one the runtime looks for). |
| `$KDEVM_STATE/` | base image, `factory.qcow2`, `work.qcow2`, `efivars.fd`, `run/` sockets, logs. Disposable. |
| `$KDEVM_SHARE/` | the one shared folder. An exchange folder, not a build tree. |

## How it works

```
Mac window (Cocoa, gl=on)  <-- virglrenderer <-- virtio-gpu-gl-pci <-- Mesa virgl <-- KWin Wayland
Mac speakers / mic         <-- SDL audiodev  <-- intel-hda + hda-micro      <-- PipeWire
NSPasteboard               <-- omarchy-vm-helper --bridge-native-clipboard <-- virtserialport <-- clipboard agent (wl-clipboard)
Mac time zone              --> omarchy-vm-helper --bridge-native-timezone  --> virtserialport --> kdevm-timezone (timedatectl)
Mac battery (IOKit)        --> omarchy-vm-helper --bridge-native-battery   --> virtserialport --> battery agent --> kernel module (BAT0/ADP0) --> UPower --> Plasma
$KDEVM_SHARE               <-- virtio-9p (guest_owner patch)               <-- ~/Mac (systemd mount unit)
localhost:2222             <-- slirp hostfwd                                 <-- sshd
QMP unix socket            <-- down / status
fw_cfg opt/kdevm/*         <-- per-launch hints (scale)                     <-- /run/kdevm (boot service) -> first-login hook
```

- **Runtime.** `runtime/build.sh` clones try-omarchy at `runtime/pin.txt`,
  runs their `macos/build-qemu-gpu-runtime.sh` unchanged except for one
  string (the product name in the Cocoa identity patch becomes "kdevm"),
  builds the Swift helper with `swift build` (the same string changed on
  the one line that names the process its bridges will attach to), and
  stages both. QEMU is staged as `bin/kdevm`, as their app build stages it
  as "Try Omarchy": the Dock, Force Quit and crash reports label a bare
  executable with its file name. The result is ad-hoc signed with the
  hypervisor entitlement. `docs/patches.md` lists
  the 23 patches and what each does.
- **Guest.** `guest/factory.zsh` (run by `guest/build.sh` directly, or by
  `kdevm.sh factory`, `rebuild` and a first-run `up`, always in the process
  that holds the lifecycle lock) downloads and verifies the Debian 13 generic
  arm64 cloud image (the generic kernel has virtio-gpu, HDA, 9p; the cloud
  kernel does not), renders `guest/user-data.yaml.tmpl`, boots it headless
  with a NoCloud seed, waits for cloud-init, runs sixteen checks that fail
  the build (the kernel modules and options it needs, the Plasma Wayland
  session, the battery module, and the two policies that keep the guest
  from sleeping or acting on the battery), and powers off.
  The factory never runs cloud-init again. The guest files in
  `guest/vendor/` come verbatim from try-omarchy: the clipboard agent, its
  unit and udev rule, a PipeWire quantum drop-in for the emulated HDA, and
  the battery side (an agent, its unit and rules, and a small kernel module
  that DKMS builds in the factory, which presents the Mac's battery as
  `BAT0`/`ADP0` so UPower and Plasma's battery applet read it like any
  laptop's). The battery is shown, never acted on: sleep is disabled in the
  guest, because a suspended guest cannot be woken on this machine type,
  and neither Plasma's power manager nor UPower does anything at a critical
  level. The time
  zone receiver (`guest/files/kdevm-timezone`) is ours: their helper writes
  the Mac's zone to a virtio port every five seconds, udev starts the
  receiver when that port exists, and it calls `timedatectl` when the zone
  differs. A factory built before this feature has no receiver;
  `kdevm.sh rebuild` adds it.
- **Lifecycle.** `kdevm.sh up` makes a qcow2 overlay on the factory, copies
  the UEFI variable template to a private file, queries the helper for the
  host audio sample rates, launches QEMU under a private umask, waits for
  QMP, starts one helper per bridge beside it (clipboard, time zone,
  battery), each tracked by pid and start time as QEMU is, and sizes the
  window. Nothing restarts a helper that exits: `status` reports it and the
  next `down` and `up` bring it back. `down`
  asks the guest's systemd to power off over ssh (QMP's ACPI button does
  nothing useful under Plasma), QMP second, kill last.

## What it is not

- **Not remote.** The window exists on the Mac that runs the VM. For a
  desktop reachable over a network, an xrdp container does that job with
  near-zero idle cost; this project exists for the GPU.
- **No hardware video decode.** VA-API fails by design on this stack; video
  decodes on the CPU. Smooth 1080p is the bar, and it is met.
- **Not a sandbox.** Guest sudo is passwordless (documented as temporary;
  it bypasses PAM and would have to go for a Touch ID sudo integration).
  The guest reaches the network through user-mode slirp; only ssh is
  forwarded, to loopback.
- **Fail-closed lifecycle.** One kernel advisory lock per state directory
  (`zsystem flock`, stock zsh), held for the command's lifetime and released
  by the OS however the command ends, crash and SIGKILL included. A command
  that finds it held exits: another command is running. A VM whose process
  cannot be inspected is reported as UNKNOWN and no verb will touch it until
  you resolve it.
- **Not an app bundle.** The runtime is ad-hoc signed, so a rebuilt
  runtime has a new identity and macOS re-asks the microphone permission.

## Roadmap

try-omarchy's helper already carries the host half of each of these, and on
the host one more bridge is now a few lines: a port and a name in the list
of bridges. The guest half is the real work and differs every time. The
battery side could be vendored verbatim, kernel module included; the time
zone receiver had to be written, because theirs is tied to Omarchy's menus.
Not started: audio device picker (choose the Mac output from Plasma's
applet), Mac camera (`v4l2loopback`), Touch ID for sudo (PAM, and the end of
passwordless sudo), USB passthrough, bridged networking. Upstream also
mirrors the Mac keyboard and language and recovers the guest clock after the
Mac sleeps; neither has been sized for kdevm. See the roadmap section of
[docs/plan.md](docs/plan.md).

## Documentation

- [docs/runbook.md](docs/runbook.md): provenance, every measurement, every
  gotcha met and how it was resolved, the fallback ladder and which rung
  held.
- [docs/plan.md](docs/plan.md): the plan this was built from, including the
  two external reviews it absorbed.
- [docs/patches.md](docs/patches.md): the 23 runtime patches.
- [CHANGELOG.md](CHANGELOG.md), [CONTRIBUTING.md](CONTRIBUTING.md),
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

The hard part of this project was done by the
[try-omarchy](https://github.com/omacom/try-omarchy) contributors (MIT): the
QEMU patch series, the VirGL-on-native-OpenGL work, the memory reclaim and
audio fixes, and the helper bridges. kdevm is the thin layer that points
that runtime at a Debian guest. Startergo's earlier
[homebrew-qemu-virgl](https://github.com/startergo) work is the ancestor of
the graphics patches.

## License

MIT (see [LICENSE](LICENSE)) for everything in this repository except one
vendored directory: `guest/vendor/try-omarchy-battery/`, try-omarchy's
battery kernel module, is GPL-2.0-only and carries its licence text. The
QEMU runtime kdevm builds is GPL-2.0 software and is not distributed here;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
