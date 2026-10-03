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

### Third pass (Codex, commit 2038ae3): lock, identity, readiness, cleanup ownership

All lifecycle mechanics moved into `lib/kdevm-common.zsh`, sourced by the
three scripts and the tests, so there is one implementation of each.

| item | what was wrong | fix | validated by |
|---|---|---|---|
| lock takeover not exclusive | a contender renamed whichever directory sat at the lock path, possibly a live owner's; a lock existed briefly without its pid | acquisition is one `os.rename` of a directory already holding the owner pid (never a pid-less lock); takeover is won by `mkdir lock/takeover`, the winner re-reads the owner and backs off if alive; an abandoned marker is honoured 30 s | live owner with a marker inside: not stolen; abandoned old marker: recovered; two contenders vs one dead owner: one holder |
| empty start time accepted | a pid-only record passed identity | `pid_state` returns `absent` for any record without a start time | pid-only record: sleeper untouched, record dropped |
| `ps` failure disowned a live VM | inspection failure deleted the pid file | tri-state `pid_state` (running, unknown, absent); `unknown` keeps the record, `status` says UNKNOWN, `up`/`down`/`destroy`/`rebuild` refuse with instructions | fake `ps` that fails: record kept, verb refused, process untouched |
| QMP helper exit 0 on EOF or error | readiness gate accepted nothing | `qmp()` exits 0 only on a `return`, 2 on connect/greeting/EOF, 3 on an error reply; `up` requires `"running": true` and re-checks liveness | fake QMP servers: close, error, ok |
| failed readiness orphaned a live child | pid file deleted, child left running | `up` terminates its own child (TERM, wait, KILL) before dropping the identity | fake QEMU that binds its sockets and never answers: terminated, non-zero exit, no pid file |
| cleanup before ownership | a lock-refused builder removed the active build's seed | `cleanup()` touches build artifacts only after `OWNED=1` (lock held or inherited); the lock is released only by its owner pid | refused builder: the other build's seed survives |

Live, after the refactor: `down` (ssh), lock released, `up` tracked and
QMP answering, duplicate `up` refused, supervisor visible as
`kdevm-bridge-supervisor <qemu pid>` with its start time recorded, one QEMU.

### Fourth pass (Codex, commit 94b1659): three items, and a design decision

Codex found that the 30 s marker timeout could still admit two owners (a
claimant paused past the timeout), that a failed or empty start-time lookup
after a matching command returned `absent` instead of `unknown`, and that a
failed start-time capture right after launch exited under `set -e` before
the child was terminated. Charles's decision on the first: do not make the
takeover more sophisticated; delete it. The lock is now **fail-closed**:
acquisition is the atomic rename of a pid-bearing directory; if a lock
exists the command exits, naming the live owner or, for a dead owner, the
`kdevm.sh unlock` verb, which removes a lock only after verifying its owner
is not running. No markers, no timeouts. An empty directory at the lock
path has no owner and is replaced atomically. The other two: `pid_state`
returns `unknown` for a failed or empty start-time lookup and `absent` only
for a successfully inspected different identity; `up` terminates its child
(TERM, wait, KILL) when it cannot record the start time, and stops an
untrackable supervisor rather than leaving it. Probes added for each
(fake `ps` that fails only `lstart=`, launch with that `ps`, unlock with a
live and a dead owner); 34 checks pass.

### Fifth pass (Codex, commit 5481e4a): the lock, settled by design

Codex found two holes in the new `unlock` verb (it treated an unverifiable
owner as gone, and two concurrent unlocks could remove a lock acquired
between them). Charles's direction: before patching, check whether the
stock zsh offers a kernel-managed advisory lock, and if so use it and delete
the custom machinery. It does. Verified 2026-10-03 on `/bin/zsh` 5.9:
`zmodload zsh/system` loads, `zsystem flock -t 0` refuses a second process
while a holder lives, the kernel released the lock after the holder was
SIGKILLed, a detached child that inherited the descriptor did not keep the
lock after its parent exited (per-process record-lock semantics), and
`-t 1` times out with status 2 after one second.

So the lock is now `$STATE/lock`, a 0600 file, locked by `zsystem flock`
on a descriptor of the command's process for its lifetime. There is no
owner pid, no stale state, no takeover, no unlock verb: a held lock means a
live command. Long-lived children (QEMU, the clipboard supervisor, the
provisioning VM) are started with that descriptor closed. `KDEVM_LOCKED=1`
still tells the factory builder that its caller holds the lock and will
wait for it. The pid plus start-time identity stays, only for the
long-lived QEMU and supervisor processes. Tests: two concurrent commands
serialise; a SIGKILLed holder is followed by an immediate successful
acquisition with nothing to clean; a detached child does not keep the lock;
the lock file is 0600 with no metadata. 29 checks pass.

### Sixth pass (Codex, commit 8329038): no delegated builder

Codex found that `take_lock` exported only a marker (`KDEVM_LOCKED=1`), so
the separately executed builder skipped the lock yet referenced a lock
descriptor it never had (`KDEVM_LOCK_FD` is close-on-exec, and the variable
was not exported), which broke `kdevm.sh factory`, `rebuild` and a first-run
`up`; and that a builder trusting an inherited marker would keep mutating
shared state after its lock-owning parent died. Charles's direction: do not
patch the export or restore delegated ownership; make the factory a
function run by the process that holds the lock. Done: the whole build body
is `kdevm_factory_build` in `guest/factory.zsh`, which first asserts
`KDEVM_LOCK_FD` is set in its own process. `guest/build.sh` is now a
thin entry point (config, `take_lock`, call). `kdevm.sh factory`, `rebuild`
and `ensure_factory` (first-run `up` and `preflight`) call the same function
in-process under their own lock. `KDEVM_LOCKED` no longer exists. The
provisioning QEMU is still launched with the lock descriptor closed.

Tests: the obsolete directory/pid lock fixture is replaced by a real
`zsystem flock` holder; a fake QEMU records its parent pid and whether the
state lock is held when `kdevm.sh factory` launches it (parent is the
`kdevm.sh` process, lock held, no `guest/build.sh` process involved); a
SIGKILL of that process mid-build leaves no builder running, the lock free
at once, and the orphaned provisioning VM makes the next factory build
refuse through the existing "a kdevm VM is running" guard. 35 checks pass.
Live: `kdevm.sh rebuild` on the real state built the factory in-process in
130 s (ssh at 17 s, cloud-init 126 s) and `up` came back tracked with QMP
answering (2026-10-03 00:31).

## Double cursor (2026-10-03, Charles)

Charles saw the Mac cursor and Plasma's cursor superimposed, moving
together. Cause: `-display cocoa,...,show-cursor=on` forces the host cursor
visible over the guest view while Plasma already draws its own cursor into
the scanout. A capture with the host-cursor overlay showed the black macOS
arrow on top of the white Breeze arrow. Fix: `show-cursor=off` (the Cocoa
frontend then hides the host cursor over the view and shows it again
outside). Host-driven tests after the change, with a small CoreGraphics
tool (`scratchpad/mouse`, not in the repo) and an evdev counter in the guest:

| test | result |
|---|---|
| inside the window | one arrow; captures with and without the host-cursor overlay differ in 0 of 230400 pixels, so it is the guest's Breeze cursor in the scanout |
| leave the window | the Mac cursor is visible at the pointer; the guest cursor stays parked where the pointer left (normal for a VM) |
| re-enter | one arrow again |
| motion | 80 injected steps: 99 ABS_X and 104 ABS_Y events on the virtio tablet; idle control: no events |
| two-finger scroll | 60 continuous scroll events: 60 REL_WHEEL_HI_RES and 5 legacy REL_WHEEL on the tablet; nothing on the pinch device |
| resize | 1614x908 to 1299x731 logical (2598x1462 pixels) through the EDID, as before |
| pinch | not synthesisable from a script (NSEvent magnification); Charles's check |

The guest cursor was not hidden or customised; the normal QEMU cursor path
works.

### Passes seven to nine (commits 3ed5901, f723dee, a7dcad6): closure

Seven: `down` stops the clipboard supervisor with the same tri-state rules
as QEMU (running: signal and remove the record only after a confirmed exit;
absent: drop the stale record; unknown: signal nothing, keep the record,
exit 2 so `destroy` and `rebuild` stop), and the offline suite became
genuinely offline: `KDEVM_OFFLINE=1` makes the runtime builder and the
base-image download refuse before any network access, the fake runtime
carries every executable so `ensure_runtime` has no fallback, and scratch
is redirected into the fixture. Eight: `status` reports the supervisor
independently of the QEMU state. Nine: the status fixture stubs `nc` and
`ssh` first in `PATH` so a test can never reach the real VM.

Verdict on `a7dcad6`: **CLEAN FOR v0.1.0**, no findings, no new defects.
Remaining items are coverage gaps the reviewer rated non-blocking three
times (duplicate tracked `up`, untracked overlay holder, malformed QMP
replies, readiness timing, more supervisor shutdown permutations). The
house rule asks for two consecutive clean passes; this is the first.

## Dock icon (2026-10-03, Charles)

The Dock showed the generic black "exec" icon for the running VM. Cause: the
Cocoa product-identity patch replaces QEMU's own icon lookup with
`cocoa_set_product_icon()`, which loads `TryOmarchy.icns` from three
directories above `argv[0]`. In their app bundle that is the Resources
folder; for `$KDEVM_RUNTIME_ROOT/current/bin/qemu-system-aarch64` it is the
runtime root, where no such file existed. The name is compiled into the
binary (our rebrand rewrites "Try Omarchy" with a space, not this name), so
the fix is to put a file there, not to rebuild: `up` converts a square PNG
(`KDEVM_ICON`, default `assets/kdevm-icon.png`) with `sips` and `iconutil`
and moves the result into place. It takes a quarter of a second, so it runs
on every `up` and there is no cache to go stale.

- `sips` exits 0 for a missing input and writes nothing; each output file is
  checked instead of the exit status.
- `iconutil -o` refuses a name that does not end in `.icns` ("Failed to
  generate ICNS"), so the temporary file is `TryOmarchy.new.icns`.
- The artwork: one gpt-image-2.5 render of a full-bleed square (a Mac title
  bar with traffic lights over a Plasma-blue desktop and a terminal with a
  green prompt; no text and no logos, so it can ship here), then cut in code
  to a superellipse 824 px wide on the 1024 canvas with a thin azure rim and
  a soft shadow. The model drew the traffic lights too close to the corner;
  they were moved 85 px inboard in code.
- Seen after `up`: the icon in the Dock with the running dot, the same size
  as its neighbours (screen capture, 3840x2160).

## Time zone mirroring (2026-10-03)

The second item of the plan's integration roadmap. The guest's time zone
follows the Mac's, live, with no guest zone configured anywhere.

How it is wired:

- Host: `up` adds a second port to the virtio-serial bus
  (`nr=8,name=dev.tryomarchy.timezone`, chardev socket `run/timezone.sock`)
  and the supervisor (removed in the 0.2.0 review; `up` now starts and
  tracks each helper itself) runs `omarchy-vm-helper --bridge-native-timezone`
  beside the clipboard helper. The helper writes one JSON line,
  `{"type": "timezone", "zone": "America/New_York"}`, every five seconds and
  reads nothing from the guest.
- Guest: `/usr/local/sbin/kdevm-timezone` (ours, `guest/files/`; their
  receiver is tied to Omarchy's menus and provisioning). It validates the
  name (plain relative path of a file under `/usr/share/zoneinfo`), compares
  it with `/etc/localtime` and calls `timedatectl set-timezone` when they
  differ. A udev rule starts it (`SYSTEMD_WANTS` on the port), so the
  service has no `enable` step and never runs when the port is absent.
- Policy: the Mac always wins. `KDEVM_TIMEZONE=off` leaves the port out;
  nothing runs on either side and the guest keeps its own zone.

Measured on a factory built from this commit, in a throwaway state
directory beside the real one (second VM, ssh on 2223):

| | |
|---|---|
| service started by udev | 2.0 s after kernel start |
| zone applied on a first boot | 2.1 s, before sddm |
| a Mac zone change with the VM running | applied in about 1 s (the helper restarted under another `TZ`), Plasma's panel clock followed without a restart |
| a zone set by hand in the guest | put back after 3.6 s |
| `KDEVM_TIMEZONE=off`, fresh overlay | no port, service inactive, guest stays on `Etc/UTC` |
| NTP | untouched: `systemd-timesyncd` active and synchronized, RTC in UTC |

What it turned up:

- **Process identity depended on the Mac's time zone.** `ps -o lstart=`
  prints the start time in the caller's zone, and the pid records compare
  that string. A VM started in one zone and inspected from another (the
  exact case this feature exists for) was reported as not running: `status`
  said so and dropped the supervisor's record, `down` would have done
  nothing. `proc_start` now pins `TZ=UTC0` and `LC_ALL=C`. A VM that is
  running across this update has records in the old rendering: power it off
  from inside the guest once.
- **The supervisor ran in ksh emulation.** zsh picks its emulation from the
  first letter of `argv[0]`, and the supervisor's is
  `kdevm-bridge-supervisor`. Harmless while it ran one command in a loop;
  with an associative array of helpers, `${(v)hp}` came back empty. The
  supervisor now starts with `emulate -R zsh`.
- `hp[$mode]=$!` stores the two characters `$!`: zsh does not expand a bare
  `$!` on the right of an array-element assignment. `${!}` works.
- A SIGTERM used to kill the supervisor and orphan its helper, which then
  ran until QEMU exited. The supervisor now stops its helpers when it is
  stopped and when QEMU ends.
- cloud-init's `timezone:` key writes `/etc/timezone` as well as the
  symlink. Nothing on Debian 13 updates that file afterwards (`timedatectl`
  does not, tzdata does not own it), so it contradicted `/etc/localtime`
  after the first change. The key is gone from the template: a fresh
  factory is on UTC until the Mac's zone arrives, and has no `/etc/timezone`.
- A guest read on a virtio port returns end-of-file at once while no host
  process is connected, so the receiver sleeps two seconds and retries
  instead of exiting.
- Not measured: this `kdevm.sh` against a factory built before the
  receiver existed. The port is then never opened in the guest; by QEMU's
  virtio-serial code the helper's 45 bytes every five seconds stay in the
  socket buffer and the helper eventually blocks in `write`, which harms
  nothing. `kdevm.sh rebuild` is the fix either way.
- A unix socket path is limited to 104 bytes on macOS. A `KDEVM_STATE` deep
  enough to push `run/clipboard.sock` past that makes QEMU refuse to start
  ("UNIX socket path is too long"). The helper also refuses a path that
  `/private` would be stripped from, so the test state directory was a
  short symlink in `~/.cache`.

## Dock name (2026-10-03, Charles)

The Dock tooltip over the running VM read "qemu-system-aarch64". QEMU here is
a bare executable, not an app bundle, so LaunchServices labels it with its
file name; the product-identity patch only sets the process name and the
menu titles.

- First attempt: rename the staged binary to `kdevm` in place. The label
  changed and both bridges died: `omarchy-vm-helper: I/O failure: ... bridge
  target is not a QEMU system process`. The helper attaches only to a
  process whose executable is named `qemu-system-<arch>` or `Try Omarchy`
  (`isQEMUSystemProcess` in `FocusedCommandSuperBridge.swift`).
- What try-omarchy does: `build-app.sh` moves `qemu-system-aarch64` to
  `Contents/Resources/runtime/bin/Try Omarchy`, and the app's own executable
  is `LSUIElement`, so the only Dock entry is the QEMU process under that
  file name. That is also why the icon is looked up three directories above
  the binary.
- What kdevm does now: the same, with its own name. `runtime/build.sh`
  rebrands that one helper line with the substitution it already applies to
  the Cocoa patch and stages QEMU as `bin/kdevm`. An older staging has no
  `bin/kdevm`, so the next `up` rebuilds the runtime; there is no in-place
  migration because the helper has to be rebuilt as well.
- A QEMU started by hand without the `virtio-gpu-gl-pci` device and
  `-display cocoa` segfaults in the patched Cocoa code and puts a macOS
  crash dialog on screen.

## Battery mirroring (2026-10-03)

The Mac's battery inside the guest as a real power supply. The host is a
laptop (`Mac16,8`), so the plan's condition for this item holds.

How it is wired, all of the guest side being try-omarchy's files verbatim
(`guest/vendor/`):

- Host: a third virtio port (`nr=7,name=dev.tryomarchy.battery`) and
  `omarchy-vm-helper --bridge-native-battery` under the same supervisor. It
  sends a whole JSON snapshot on every IOKit power change and every 30 s.
- Guest: `try_omarchy_battery`, a 451-line kernel module (GPL-2.0-only)
  built by DKMS in the factory, registers `BAT0` and `ADP0` and takes one
  snapshot per write on a root-only sysfs attribute. Their Python agent
  reads the port and writes that attribute. UPower and Plasma's battery
  applet (`powerdevil`) need nothing else.
- No simpler design exists here: the state changes all the time, so a
  boot-time hint would be worthless.

Measured on a factory built from this commit (throwaway state directory,
second VM):

| | |
|---|---|
| DKMS build of the module, Debian kernel 6.12.111 | 7 s; loads at boot through `modules-load.d` |
| agent started | 2.1 s after kernel start |
| guest reading against `pmset -g batt` | 80%, not charging, AC online, 56 cycles on both sides |
| Plasma | the battery icon is in the tray while discharging (a 42% discharging state written to the module by hand); hidden behind the arrow on AC and not charging, as on any laptop |
| factory | 102 to 111 s (was 93 to 101), 4.3 GB on disk (was 4.0), `dkms` + headers + compiler about 300 MB |

What it turned up:

- **A suspended guest is a dead guest.** Sleep is suspend-to-idle here
  (`/sys/power/mem_sleep` is `[s2idle]`). After `powerdevil` suspended the
  test guest (an idle policy set on purpose), QEMU still reported
  `running`, `system_wakeup` answered "wake-up from suspend is not supported
  by this guest", an injected key did nothing, ssh timed out, and `down` had
  to kill it. Plasma's own Sleep button could already do this in 0.1.0.
  Sleep is now disabled where it is decided:
  `/etc/systemd/sleep.conf.d/kdevm.conf`. logind answers `CanSuspend=no`,
  `systemctl suspend` fails with "Sleep verb 'suspend' is disabled by
  config", and a user-level policy asking for sleep after 60 s idle left the
  guest running 197 s later.
- Do not restart `systemd-logind` in a running guest to pick up a config
  change: it takes the graphical session down with it.
- `powerdevil` is installed for the applet only. `/etc/xdg/powerdevilrc`
  sets no action at a critical battery level and no dimming or screen-off on
  idle, in all three profiles; the key names were read out of
  `libpowerdevilcore` (UTF-16 strings), since the package ships no schema
  file. That `/etc/xdg` is honoured was shown by the sleep test above.
- `powerdevil` logs "Charge thresholds are not supported by the kernel for
  this hardware" and a failed brightness helper at start. Both are true and
  harmless: there is no backlight and the charge limit is read-only.
- DKMS signs the module with a self-signed key it generates in the factory,
  and the kernel logs that an out-of-tree module taints it. Expected: the
  guest does not use Secure Boot.
- The module is built for the newest installed kernel, not the one
  cloud-init happens to run on (`dkms install -k`), and the factory's
  capability checks fail the build if it is missing for that kernel.
- The first test of the path used a port hot-plugged over QMP
  (`chardev-add`, then `device_add virtserialport`), which works on the
  running bus and is a quick way to try the next bridge.

## 0.2.0 review, discovery pass one (Codex, commit 5763b80)

Read-only review of `v0.1.0..5763b80`. Five blockers, four should-fix. Each
was checked here before anything was changed.

| # | finding | checked how | disposition |
|---|---|---|---|
| 1 | updating with a 0.1 VM running: `destroy`/`rebuild` unlink the live overlay | reproduced on 5763b80 with a 0.1-style record and a live process: overlay removed | fixed: `refuse_if_stray` in `down` (so `destroy` and `rebuild` inherit it) and `up`; fixed-string match on the process table |
| 2 | UPower shuts the guest down at a critical battery level | reproduced: 1% discharging, powered off after 22 s; `GetCriticalAction` said `PowerOff` | fixed: `CriticalPowerAction=Ignore` in `UPower.conf`, checked by the factory build; still up after 80 s live and on a cold boot of a rebuilt factory |
| 3 | supervisor can signal a reused helper pid | by reading: the helper table held bare pids | fixed by deletion: no supervisor; each helper has its own "pid start-time" record, checked against its command line |
| 4 | supervisor exit taken as proof its helpers ended | by reading | fixed by deletion: `down` confirms each helper's exit; one that will not end keeps its record, `down` exits 2 |
| 5 | concurrent runtime builds can stage `kdevm` beside an unrebranded helper | by reading; needs two builds at once | fixed: `zsystem flock` on the runtime root and on the scratch checkout |
| 6 | `KDEVM_TIMEZONE` validated after the runtime and factory builds | by reading | fixed: validated first |
| 7 | battery seed check runs when PyYAML is absent | by reading | fixed: inside the conditional |
| 8 | helper lookup for `status` is a regex over the socket path | by reading | fixed by deletion: `status` reads the records; the command-line pattern quotes its literal parts |
| 9 | Dock icon temp file shared by state directories on one runtime | by reading; cosmetic | fixed: per-process name |

- The supervisor (3, 4, 8) was Charles's call: delete it. The bridge
  helpers are now handled by the pid-record code the 0.1.0 review hardened,
  one record per bridge. What is given up is restart: a helper that exits
  stays down, `status` prints `NOT RUNNING` for that bridge, and the next
  `down` and `up` restore it. On the real VM the three helpers end by
  themselves within two seconds of QEMU exiting (guest powered off from
  inside, no `down`); their records are dropped by the next `up` or `down`,
  and `status` itself no longer changes anything.
- UPower 1.90.9 does not read `/etc/UPower/UPower.conf.d/`: a drop-in there
  changed nothing (`GetCriticalAction` still `PowerOff`). The main file has
  to be edited, and `Ignore` needs `AllowRiskyCriticalPowerAction=true`.
- A battery state can be written to the module by hand for tests: stop the
  agent, then one line to `/sys/devices/platform/try-omarchy-battery/state`.

## Rules that are easy to forget

- Never let the guest sleep: on this machine type it cannot be woken. Sleep
  is disabled in `/etc/systemd/sleep.conf.d/kdevm.conf`; keep it that way.

- `gic-version=3` is mandatory under HVF on this QEMU; it rejects GICv2.
- Never attach the Homebrew `edk2-arm-vars.fd` writable. Every kdevm boot
  (provisioning, preflight, up) uses its own copy.
- The `generic` Debian image, not `genericcloud`: the cloud kernel lacks
  virtio_gpu, snd_hda_intel and friends. `guest/build.sh` fails the factory
  if any required module or CONFIG is missing.
- The lifecycle lock is a kernel advisory lock (`zsystem flock`) on
  `$STATE/lock`, held by the command's process. Nothing to clean after a
  crash. If a command says another is running, one is.
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
