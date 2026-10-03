# Changelog

## Unreleased

First review pass on the work below (Codex, discovery, commit 5763b80); the
fixes so far:

- `down`, `destroy` and `rebuild` refuse when a QEMU has the overlay open
  but the pid record does not vouch for it. Before, such a VM counted as
  "not running", and `destroy` or `rebuild` then removed the overlay and the
  UEFI variables from under it. Updating from 0.1.0 with the VM still
  running produced exactly that record mismatch.
- The guest no longer powers itself off at a critical battery level. UPower
  has its own critical action, separate from Plasma's; with sleep disabled
  it fell through to PowerOff, and a guest at 1% shut down 22 seconds later.
  It is now `Ignore`, and the factory build fails if that did not take.
- Two runtime builds can no longer share a scratch checkout or a runtime
  root (kernel locks in `runtime/build.sh`): the second could revert the
  first one's rebrand under its compiler.
- `KDEVM_TIMEZONE` is validated before anything is built; the rendered-seed
  checks are skipped together when PyYAML is missing; the Dock icon is built
  under a name no other `up` shares. Five more offline checks (70 in all).

- Battery mirroring: the Mac's battery appears in the guest as a real
  `BAT0`/`ADP0` (charge, state, time estimates, cycle count), so UPower and
  Plasma's battery applet read it like any laptop's. try-omarchy's helper
  (`--bridge-native-battery`) sends snapshots on a third virtio port; their
  guest side is vendored verbatim: an agent and a small kernel module that
  DKMS builds in the factory (GPL-2.0-only; the rest of the repository stays
  MIT). The factory gains `dkms`, the kernel headers, a compiler and
  `powerdevil` (about 300 MB) and a thirteenth capability check. A Mac
  without a battery shows as mains only. Needs `kdevm.sh rebuild`.
- Sleep is disabled in the guest (`/etc/systemd/sleep.conf.d`). A suspended
  guest cannot be woken on this machine type: QEMU reports it as running,
  `system_wakeup` is refused and keys do nothing, so it had to be killed.
  That was already reachable from Plasma's Sleep button; with a power
  manager installed it would also have been reachable from an idle timer.
  The battery is shown, never acted on: no action at a critical level, no
  dimming or screen-off on idle.
- The template inlines files with one generic token
  (`@@B64:<path under guest/>@@`); the renderer no longer takes a list of
  files. Two more offline checks (65 in all).

- Dock name: the running VM is labelled "kdevm" in the Dock, Force Quit and
  crash reports, not "qemu-system-aarch64". The runtime stages QEMU as
  `bin/kdevm`, which is how try-omarchy's app build gets its own name there,
  and the one line of their helper that names the process its bridges accept
  is rebranded to match. The next `up` rebuilds the runtime once (about two
  minutes); macOS may ask for the microphone again.

- Time zone mirroring (the second roadmap item): the guest's time zone
  follows the Mac's, live. try-omarchy's helper
  (`--bridge-native-timezone`) writes the Mac's zone to a second virtio port
  every five seconds; a small root service in the guest
  (`guest/files/kdevm-timezone`, started by udev when the port exists)
  applies it with `timedatectl`. The Mac always wins; `KDEVM_TIMEZONE=off`
  leaves the port out and the guest keeps its own zone. Needs a factory
  built from this version: `kdevm.sh rebuild`. The template no longer sets
  a zone (it was America/New_York): a fresh guest is on UTC for the two
  seconds before the Mac's zone arrives, and stays there with mirroring off.
- Process identity no longer depends on the Mac's time zone. `ps` prints a
  process's start time in the caller's zone, so a VM started in one zone
  and inspected from another was reported as not running; the lookup is now
  pinned to UTC and the C locale. Update with the VM stopped: a VM that is
  running across the update is no longer recognised; kdevm refuses to treat
  it as stopped and it has to be powered off from inside the guest.
- One supervisor now runs every host bridge (clipboard, time zone), restarts
  a helper that exits, and stops its helpers when it is stopped. Its files
  are `bridges.pid` and `bridges.log` (an old `clipboard-bridge.log` in the
  state directory can be deleted), and `status` reports one `bridges` line
  with each helper's pid. The supervisor had been running in zsh's ksh
  emulation because its process name starts with "k"; it now selects zsh.
  Twelve more offline checks (63 in all), nine of them a first end-to-end
  run of `up`, `status` and `down` against a fake QEMU that answers QMP.

- Dock icon: `kdevm.sh up` builds `TryOmarchy.icns` in the runtime root from
  `assets/kdevm-icon.png` (or the square PNG named by `KDEVM_ICON`), which is
  where the runtime's Cocoa product-identity patch looks for it. The Dock
  showed the generic black "exec" icon before. No runtime rebuild is
  involved; an unusable icon is a warning and the desktop still starts. Two
  more offline checks (51 in all).

## 0.1.0 (2026-10-02)

First release. One evening from empty directory to an accepted desktop,
then an independent code review (Codex) with seven findings, all fixed
before tagging:

- first-run password generation no longer dies of SIGPIPE under pipefail
  (Python `secrets` instead of a `tr | head` pipeline);
- `pkgconf` added to the documented prerequisites (try-omarchy's build
  needs `pkg-config`, which Homebrew's qemu bottle does not provide);
- `factory --force` refuses while an overlay still backs the factory
  (`rebuild` is the verb that drops it first);
- saved pids are trusted only if the live process is our QEMU on our
  overlay, so a reused pid can never be signalled;
- one lock per state directory across every state-changing verb and the
  factory build, with dead-holder reclaim;
- `umask 077` from the first line of both scripts, state directory 0700,
  disks and the UEFI vars 0600, the cloud-init seed (plaintext password)
  removed on failure as well as success;
- the guest password and ssh key are rendered as JSON strings (valid YAML
  double-quoted scalars), so any password survives;
- plus one found while validating: values in `~/.config/kdevm/env` are
  defaults and an explicit environment variable now wins.

A second review pass found the lock trap was function-scoped in zsh (so it
protected nothing), the supervisor identity check too loose, surrogate
pairs in the YAML for non-BMP passwords, a config loader that dropped
non-KDEVM keys, tests that could touch real files, and cleanup that a
failed `kill` could abort. All fixed; while validating, `up` gained two
more guards (process alive and QMP answering after the socket wait, no
start beside an untracked QEMU on the overlay).

A third pass closed the remaining lifecycle gaps: the lock is now one
atomic rename of a pid-bearing directory with takeover serialised by a
marker, process identity is tri-state (running, unknown, absent) with a
mandatory start time and refuses to act on what it cannot inspect, the QMP
helper fails on EOF and error replies, a QEMU that never becomes ready is
terminated before its identity is dropped, and a build that was refused the
lock touches nothing. The shared logic lives in `lib/kdevm-common.zsh`.

A fourth pass made start-time inspection failures `unknown` rather than
`absent` and terminates a child whose start time cannot be recorded. A fifth
pass replaced the lock outright: it is now a kernel-managed advisory lock
(`zsystem flock` from the stock zsh) held on a descriptor for the command's
lifetime and released by the OS on exit, error, crash or SIGKILL. No owner
metadata, no stale-lock recovery, no `unlock` verb.

A sixth pass removed the last delegation: the factory build is a function
(`guest/factory.zsh`) executed by the process that holds the lock, whether
that is `guest/build.sh` directly or `kdevm.sh factory`, `rebuild` and a
first-run `up`. No inherited "locked" marker exists any more.

Three further passes made the clipboard supervisor's shutdown and status
reporting tri-state like QEMU's, made the test suite provably offline
(`KDEVM_OFFLINE=1` refuses any fetch or build; network commands are
stubbed in fixtures), and ended with a clean review verdict.

`tests/checks.sh` keeps every probe from all nine passes runnable offline
(49 checks, including fake `ps`, fake QMP servers, fake QEMUs, a SIGKILLed
lock holder, a SIGKILLed factory build, and stubbed `nc`/`ssh`).

- Runtime: try-omarchy's patched QEMU 11.1.1 (HVF, Cocoa + VirGL, libslirp,
  SDL duplex audio, virtio-9p) built by their own script from a pinned
  commit, plus their Swift helper for the clipboard bridge. Product name
  rebranded to kdevm in the one patch that hard-codes it.
- Guest: Debian 13 generic arm64 cloud image provisioned once by cloud-init
  into a factory image (Plasma 6 Wayland, sddm auto-login, Google Chrome
  arm64, Firefox ESR, PipeWire, try-omarchy's clipboard agent, a 9p mount
  for the shared folder), run from a throwaway qcow2 overlay.
- Lifecycle: `kdevm.sh runtime | factory | preflight | up | down | destroy |
  rebuild | status | ssh | console`.
- Proven on an M4 Pro, macOS 27.0.1: Plasma Wayland with KWin compositing on
  virgl in a native resizable HiDPI window; live resize through the EDID;
  Chrome on native Wayland with hardware compositing, rasterization and
  WebGL; sound out and microphone in; clipboard text and PNG both ways;
  shared folder; ssh. Factory build about 110 s, boot to desktop 14 s, idle
  about 7% of one core, unused guest memory returned to macOS.
- Cocoa display runs with `show-cursor=off`: with it on, the Mac cursor sat
  on top of Plasma's own cursor as a double cursor.
- Known limits: local only; no hardware video decode (CPU decode); a
  rebuilt runtime has a new ad-hoc signature and macOS re-asks the
  microphone permission; guest sudo is passwordless by default.
