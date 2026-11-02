# Changelog

## 0.3.0 (unreleased)

The runtime moves to try-omarchy v1.3.0: twelve new QEMU and VirGL patches,
most of them fixes for things kdevm was exposed to, plus their current guest
pieces and one kernel setting for the M4. No new kdevm feature; one new
verb (`state`).

### Upgrading from 0.2.2

1. Stop the VM with the version that started it (`./kdevm.sh down`), then
   update the checkout.
2. The next `./kdevm.sh up` rebuilds the runtime once (about two minutes).
   The new binary has a new ad-hoc signature, so macOS asks for the
   microphone again the first time the guest records.
3. Run `./kdevm.sh rebuild` for the guest-side changes (the battery module,
   the bridges' new paths, the kernel setting). It replaces the overlay.
   The old runtime stays beside the new one under `$KDEVM_RUNTIME_ROOT`;
   to go back, check out 0.2.2, point `current` at it, and `rebuild`.

### Changed

- **Runtime pinned to try-omarchy v1.3.0** (13d63df, 2026-10-24; was
  82927e9, 2026-10-03). Same QEMU 11.1.1 source; libslirp and virglrenderer
  are now pinned by commit upstream. `docs/patches.md` describes all 35
  patches. The twelve new ones kdevm inherits:
  - no App Nap: a VM whose window is hidden, minimized or behind a locked
    screen no longer crawls at background priority;
  - a guest rebooted while its window is small boots instead of hanging in
    the firmware (it now gets at least 800x600);
  - sound: the main loop runs at interactive priority, HDA output no longer
    catches up a stall in one burst, and the Mac's audio devices are opened
    off the main lock, so a slow microphone open (a pending permission)
    no longer freezes the whole VM for minutes;
  - pointer mapping per axis, a VirGL flush for the firmware console,
    guest Super held for a whole Command chord, two-finger swipe back and
    forward in browsers, Korean Caps Lock (inert here);
  - notch support, which kdevm turns off (`TRYOMARCHY_NOTCH=0`): it needs a
    guest that knows where the camera housing is, and Plasma does not.
- **The build no longer rewrites any upstream patch.** Their product-identity
  patch now takes the window, menu and process name from QEMU's `-name`,
  which kdevm has always passed. The one edit to their tree is the helper
  line that names the process its bridges attach to. The build fails closed
  if the `-name` contract leaves the patch.
- **Guest pieces re-vendored from v1.3.0.** Upstream moved them into an Arch
  package; the bridges now live in `/usr/bin` (where their unit files point)
  and the udev rules carry upstream's new names. The clipboard bridge and
  the PipeWire drop-in are unchanged byte for byte. The battery module is
  1.3.0: it reports the current draw (`current_now`) so UPower can estimate
  the time left, and a host bridge that dies now drops the battery instead
  of freezing a stale level.
- **SME hidden from the guest** (`arm64.nosme` on the kernel command line,
  through a GRUB drop-in). The M4 reports SME without SVE and the hypervisor
  cannot hide it, so programs that run an SVE instruction outside streaming
  mode (libyuv in Chromium and Electron apps) died with SIGILL. Chips before
  the M4 have no SME, so nothing changes there. The factory build fails if
  the setting did not reach `grub.cfg`.
- **`up` rebuilds the runtime when `runtime/pin.txt` moves.** It used to
  build only when no runtime was staged, so an update that moved the pin
  left the old QEMU and helper in place. The old staging stays beside the
  new one, and a pin that was staged earlier is pointed at again without a
  build; `status` says when the pin and the staged runtime differ.
- **A failed factory build flushes the guest before keeping its disk**, so
  the `.failed` image shows what the checks saw.
- **fedvm is named as the sister project** in the README, CONTRIBUTING and
  the runbook: it runs this runtime and vendors the same guest files, so a
  pin bump here is a pass there too.
- **The Dock icon lives in the state directory** (`icon.icns`) and reaches
  QEMU through `TRYOMARCHY_PRODUCT_ICON`, which the new runtime reads. It
  used to be written into the runtime root under the one name the old
  runtime looked for, so kdevm and fedvm, which share the runtime,
  overwrote each other's picture on every `up`. The old
  `TryOmarchy.icns` beside the pins is no longer written or read by kdevm
  (the runtime only falls back to it when the variable is unset) and can
  be deleted.
- **A quiet window before the desktop.** GRUB's text now goes to the
  serial port (where `kdevm.sh console` reads it), the framebuffer cursor
  no longer blinks on the black screen, and the login prompt that flashed on
  tty1 before sddm is gone (`getty@tty1` masked; the serial login stays).
  The firmware's one or two seconds of text are written before any guest
  code runs and cannot be helped. The kernel's only console was already the
  serial port, so no kernel or systemd text reached the window.
- **The time zone receiver skips the helper's wake prompt** (`{"type":
  "wake"}`, which the v1.3.0 bridge can write on the same port) without
  logging a rejection. kdevm does not act on it.

### New

- `kdevm.sh state`: the VM's state in one JSON line for dashboards
  (`{"v":1,"tech":"qemu","name":"kdevm","state":"stopped","mem_mb":8192}`).
  States are absent, stopped, running, busy (another kdevm command holds
  the lock) and unknown. It is read-only, never waits on the lock and logs
  in to nothing, so it answers at once. `status` is unchanged.

### Known limits

- Guest clock recovery after the Mac sleeps (upstream's v1.1.0 feature) is
  not taken: it depends on their guest package, and no drift has been
  reported here. The audio picker, camera, Touch ID and keyboard-language
  integrations are still not taken.
- Not verified on the second machine (M3 Pro) at the time of writing.

## 0.2.2 (2026-10-03)

One change to a default, for Macs with little memory. No new features.

### Upgrading from 0.2.1

Update the checkout, with the VM stopped as for any update. Nothing needs
rebuilding: the runtime pin and the guest are unchanged, and guest memory
is set at each `up`. On a Mac with 16 GB or more nothing changes.

### Changed

- **The guest's default memory follows the Mac's.** A Mac with less than
  16 GB now gets a 4 GB guest; every other Mac keeps 8 GB, so nothing
  changes on 16 GB and up. The flat 8 GB default used to promise an 8 GB
  Mac's whole memory to the guest. `KDEVM_MEM_MB` still overrides, and the
  setting applies at the next `up` with nothing to rebuild. kdevm has
  never been run on a Mac with less than 16 GB, so whether it works there
  at all is unknown; the README says so.

## 0.2.1 (2026-10-03)

A first-run release: what a newcomer meets between `git clone` and a
desktop. kdevm was installed on a second Mac by following the README, and
this is what that turned up. No new features.

### Upgrading from 0.2.0

Update the checkout, with the VM stopped as for any update. Nothing needs
rebuilding: the runtime pin and the guest are unchanged.

### Changed

- **The scripts ignore your shell startup files.** `kdevm.sh`, both build
  scripts and the checks now start as `/bin/zsh -f`. Before, a `~/.zshenv`
  that defined aliases (`rm -i`, a coloured `grep`) or set options such as
  `KSH_ARRAYS` or `NO_CLOBBER` changed how they ran; with those options
  nothing ran at all. Found by running the checks under such a file; they
  pass with and without one.
- **A missing ssh key is reported before anything is built.** `up`,
  `factory` and `rebuild` used to build the runtime (two minutes) and only
  then say that no ssh public key was found; `rebuild` had dropped the
  overlay by then.
- **A quiet runtime build.** The first `up` used to scroll about three
  thousand lines of try-omarchy's build output, over a hundred of them
  compiler and `install_name_tool` warnings in code that is not kdevm's;
  none was a problem and all looked like one. The output now goes to
  `runtime-build.log` in the build directory, the terminal shows the
  build's download and stage lines, and a failed build prints the log's tail.
- **Run on a second machine**: an M3 Pro on macOS 26.6.2, from a fresh
  clone by the README's steps, removal included. The record is in
  [docs/runbook.md](docs/runbook.md).
- **README rewritten for a first-time reader**: a screenshot, what you get
  in plain words, what the first run asks of you, how to remove everything.
  The internals moved under "How it works".

## 0.2.0 (2026-10-03)

Three host integrations from the roadmap, a guest that can no longer strand
itself, and a lifecycle rebuilt on facts the kernel keeps. The work was
reviewed in six passes by two independent reviewers on different models
(Codex and Claude Opus 5.5) against a frozen rubric; the pass-by-pass record,
with every finding and what was done about it, is in
[docs/runbook.md](docs/runbook.md).

### Upgrading from 0.1.0

1. Stop the VM with the version that started it (`./kdevm.sh down`), then
   update the checkout. A VM left running across the update is not
   recognised by the new scripts: they refuse to touch its disk, and it has
   to be powered off from inside the guest.
2. The next `./kdevm.sh up` rebuilds the runtime once (about two minutes).
   macOS may ask for the microphone again.
3. Run `./kdevm.sh rebuild` for the guest-side changes. It replaces the
   overlay; the factory grows by about 300 MB.
4. An old `clipboard-bridge.log` in the state directory can be deleted.

### New

- **Time zone mirroring.** The guest's time zone follows the Mac's, live.
  try-omarchy's helper (`--bridge-native-timezone`) writes the Mac's zone to
  a virtio port every five seconds; a small root service in the guest
  (`guest/files/kdevm-timezone`, started by udev when the port exists)
  applies it with `timedatectl`. The Mac always wins. `KDEVM_TIMEZONE=off`
  leaves the port out and the guest keeps its own zone (UTC in a fresh
  factory: the template no longer sets one).
- **Battery mirroring.** The Mac's battery appears in the guest as a real
  `BAT0`/`ADP0` (charge, state, time estimates, cycle count), so UPower and
  Plasma's battery applet read it like any laptop's. The helper
  (`--bridge-native-battery`) sends snapshots on another virtio port;
  try-omarchy's guest side is vendored verbatim: an agent and a small
  kernel module that DKMS builds in the factory. A Mac without a battery
  shows as mains only. The battery is shown, never acted on: neither
  Plasma's power manager nor UPower does anything at a critical level.
- **Dock name and icon.** The running VM is "kdevm" in the Dock, Force Quit
  and crash reports, with its own icon (`assets/kdevm-icon.png`, or the
  square PNG named by `KDEVM_ICON`). The runtime stages QEMU as `bin/kdevm`,
  which is how try-omarchy's app build gets its own name there, and the one
  line of their helper that names the process its bridges accept is
  rebranded to match.

### Fixed (present in 0.1.0)

- **A suspended guest could not be woken.** QEMU reported it as running,
  `system_wakeup` was refused and keys did nothing, so it had to be killed;
  Plasma's Sleep button was enough to get there. Sleep is now disabled in
  the guest (`/etc/systemd/sleep.conf.d`), and the factory build fails if
  logind does not agree.
- **`destroy` and `rebuild` could remove the disks of a running VM** that
  the pid record did not vouch for, which is what updating under a running
  VM produces. `up`, `down`, `destroy` and `rebuild` now refuse while the
  overlay is open in another process. The test is the disk's own lock (QEMU
  locks every image it opens), so it does not depend on the record, on how
  the state directory's path is spelled, or on any command line.
- **Process identity depended on the Mac's time zone and locale.** `ps`
  prints a start time in the caller's zone, so a VM started in one zone and
  inspected from another was "not running". The lookup is pinned.
- **`down` could signal the wrong process or lose track of QEMU.** Its
  forced stop sent SIGKILL to a bare pid after a delay and dropped the
  record without confirming the exit. Every signal is now sent only after
  the record has been checked against the live process, and a record goes
  only when the exit is confirmed; otherwise `down` exits 2 and `destroy`
  and `rebuild` remove nothing.
- **`status` could delete a record** that a concurrent `up` had just
  written, and let ssh add the guest key to `known_hosts`. It now writes
  nothing.
- **Seed rendering.** A password such as `@@SSHKEY@@` was expanded by the
  next replacement, and one containing DEL, a C1 control, U+2028, U+FFFE or
  U+FFFF broke the YAML. The renderer makes one pass and escapes those
  characters.
- A state directory with pattern characters in its name (`[`, `*`) hid a
  live QEMU from its own record. A crashed QEMU's sockets were left behind
  by `down`. Two runtime builds at once could work in the same checkout;
  builds now hold a lock that their compilers inherit.

### Changed

- **One way to start a process and one way to stop one**, for QEMU, every
  bridge helper and the factory's provisioning VM (`launch_tracked` and
  `stop_tracked` in `lib/kdevm-common.zsh`). A process registers itself
  before it exists: its launcher writes pid and start time to a private
  file and hard-links it to the record, which the kernel refuses if a
  record is already there, and only then execs. `kdevm.sh` sends no signal
  of its own.
- **No bridge supervisor.** `up` starts one helper per bridge (clipboard,
  battery, time zone), each with its own record, `bridge-<name>.pid`.
  `status` has a line per bridge. Nothing restarts a helper: one that exits
  is reported `NOT RUNNING` and comes back with the next `down` and `up`.
  (0.1.0 ran the clipboard helper in a restart loop under a supervisor,
  which, it turned out, had been running in zsh's ksh emulation because its
  name starts with "k".)
- **Factory.** It gains `dkms`, the kernel headers, a compiler and
  `powerdevil`, takes about two minutes to build (102 to 137 s over nine
  builds) and 4.3 GB on disk, and runs sixteen checks that fail the build,
  among them the battery module, the no-sleep setting and UPower's critical
  action.
- **Template.** Files are inlined with one generic token
  (`@@B64:<path under guest/>@@`); `KDEVM_TIMEZONE` is validated before
  anything is built.
- **Licence.** `guest/vendor/try-omarchy-battery/` (the kernel module) is
  GPL-2.0-only and carries its licence text; everything else stays MIT.
- **Tests.** 98 offline checks (49 in 0.1.0), with `ssh` and `nc` replaced
  by failing stubs for the whole suite. They include end-to-end runs of
  `up`, `status`, `down` and `destroy` against a fake QEMU that answers QMP,
  and direct tests of the two lifecycle functions.

### Known limits

- A bridge helper that dies stays down until the next `down` and `up`.
- The factory's own checks and the runtime build's rename verification run
  only inside a real build; the offline suite does not exercise them.
- The factory build's guard against a leftover provisioning VM matches
  command lines, so a process that merely names the disk (a log viewer)
  makes `factory` and `rebuild` refuse. It fails closed.
- A launcher frozen for longer than its caller waits (five seconds) could
  still register in the instant after a later `destroy` has checked the
  disk. Launchers give up by themselves after four seconds.
- Boot time, idle CPU and idle memory in the README were measured on 0.1.0
  and have not been measured again with the bridges and the power applet.

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
