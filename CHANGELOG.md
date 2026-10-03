# Changelog

## Unreleased

First review pass on the work below (Codex, discovery, commit 5763b80); the
fixes so far:

- `down`, `destroy`, `rebuild` and `up` refuse while the overlay is open in
  another process. The test is the disk's own lock: QEMU locks every image
  it opens and `qemu-img` will not open one that is held for writing. It
  does not depend on the pid record, on how the state directory's path is
  spelled (`/tmp/state/.` or a symlink names the same disk), or on any
  process's command line. Before, a VM the record did not vouch for counted
  as "not running", and `destroy` or `rebuild` then removed the overlay and
  the UEFI variables from under it; updating from 0.1.0 with the VM still
  running produced exactly that mismatch.
- The guest no longer powers itself off at a critical battery level. UPower
  has its own critical action, separate from Plasma's; with sleep disabled
  it fell through to PowerOff, and a guest at 1% shut down 22 seconds later.
  It is now `Ignore`, and the factory build fails if that did not take.
- Two runtime builds can no longer share a scratch checkout or a runtime
  root: the second could revert the first one's rebrand under its compiler.
  The locks are inherited by everything a build starts, so they hold while
  a compiler left behind by a killed build is still running.
- `KDEVM_TIMEZONE` is validated before anything is built; the rendered-seed
  checks are skipped together when PyYAML is missing; the Dock icon is built
  under a name no other `up` shares.
- The bridge supervisor written for this release is gone (see below): the
  review found that it tracked its helpers by bare pid and that its own exit
  was taken as proof that they had ended. Each helper now has a full
  identity record of its own, a helper that will not end keeps its record
  and makes `down` exit 2, and `status` no longer searches the process table
  by socket path.
- Second review pass (commit b133a06). Each helper now registers itself: a
  launcher writes its own pid and start time to the bridge's record and
  then becomes the helper, so no helper ever runs without a record and none
  is ever signalled by a bare pid; one that cannot register is not started.
  `status` writes nothing at all (it could delete the record of a VM that a
  concurrent `up` had just started).
- First closure pass (commit bde8dd5) against the frozen rubric: eleven
  items not met, most of them in code unchanged since 0.1.0 that the rubric
  now covers. There is one way to start a process and one way to stop one,
  used for QEMU and for every helper. `launch_tracked`: the record file is
  written by the launcher itself and put in place with an atomic hard link
  (see the next entry), so a delayed launcher can never touch a newer
  session's record, and QEMU too is recorded before it exists. `stop_tracked`: every signal, SIGKILL included,
  is sent only after the record has been checked against the live process,
  and a record is dropped only once the exit is confirmed; a QEMU that
  cannot be confirmed stopped keeps its record, `down` exits 2, and
  `destroy` and `rebuild` remove nothing (they also check the disk's lock
  again just before removing). Also: `down` clears sockets a crashed QEMU
  left; `status` no longer lets ssh write `known_hosts`; the Cocoa rename in
  the runtime build is verified like the helper's; the time zone receiver
  drops an overlong line whole instead of reading its tail as a message;
  the seed renderer makes one pass, so a password such as `@@SSHKEY@@` stays
  a password; `ssh` and `nc` are failing stubs for the whole test suite.
- Second closure pass (commit 47c0a61), by two reviewers on different
  models: sixteen and seventeen of twenty-two items met. A process now
  registers with one atomic step: its launcher writes pid and start time to
  a private file and hard-links it to the record, which the kernel refuses
  if a record is there. A record is never half-written, never overwritten,
  and a caller that gives up on a slow launcher cancels it with an empty
  record the launcher cannot link over (this replaces the first closure
  pass's descriptor hand-off, which left a few milliseconds in which a
  process could end up running with no record). The factory build's
  provisioning VM is started and stopped by the same two functions as
  everything else (it was still signalled by a bare pid); a record that
  exists but cannot be read is kept, not deleted; a failed `up` removes its
  sockets even when QEMU could not be confirmed stopped; a password with
  DEL, a C1 control or U+2028 no longer breaks the seed; the README has an
  Upgrading section; checks that need the builder's tools are skipped
  without them; several checks were strengthened so that removing the
  behaviour they name makes them fail; and the tests end only processes
  they started, by pid.
- Third closure pass (commit 0c402b5), both reviewers again: nineteen and
  twenty of twenty-two items met, and nothing that can cost data. Fixed: a
  state directory with pattern characters in its name (`[`, `*`) is matched
  as literal text; a failed factory build leaves its disk and vars copy
  alone if the provisioning VM cannot be confirmed stopped; a launcher gives
  up by itself after four seconds; U+FFFE and U+FFFF are escaped in the
  seed. Found while fixing: inside its own EXIT trap zsh reported success
  for a failed command substitution, so the identity check read an exited
  process as present; it now reads `kill`'s words, not its status. Left as
  stated limits: the factory build's `pgrep` guard can be tripped by a
  process that only names the disk (it fails closed), and a launcher frozen
  for longer than its caller waits could still register in the instant
  after a later `destroy` has checked the disk. 98 offline checks in all.

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
- Host bridges are tracked one by one. `up` starts one helper per bridge
  (clipboard, battery, time zone) and gives each its own record,
  `bridge-<name>.pid`, checked by command line and start time exactly as
  QEMU's is; `status` has a line per bridge and `down` confirms each exit.
  0.1.0 ran the clipboard helper in a restart loop under a supervisor
  process (which, it turned out, had been running in zsh's ksh emulation
  because its name starts with "k"). There is no supervisor now and nothing
  restarts a helper: one that exits is reported `NOT RUNNING` and comes back
  with the next `down` and `up`. An old `clipboard-bridge.log` in the state
  directory can be deleted.

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
