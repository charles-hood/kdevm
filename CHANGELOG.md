# Changelog

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

`tests/checks.sh` keeps every probe from all six passes runnable offline
(35 checks, including fake `ps`, fake QMP servers, fake QEMUs, a SIGKILLed
lock holder, and a SIGKILLed factory build).

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
