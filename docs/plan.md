# kdevm: the Debian 13 KDE desktop as a GPU-accelerated QEMU VM on the M4 Pro

Revision 4 (2026-10-02). Rev 2 reconciled with ChatGPT's own plan
(`~/Downloads/debian13-plasma-try-omarchy-plan.md`); rev 3 folds in
ChatGPT's review of rev 1 (`~/Downloads/kdevm-review-notes-for-claude-code.md`);
rev 4 applies the two items in its final delta
(`~/Downloads/kdevm-final-review-delta-for-claude-code.md`): the display-sync
helper reads the live EDID from sysfs, and the preflight is hardened against
seat-ACL false negatives. Changes are marked **[rev 2]**, **[rev 3]**,
**[rev 4]**. The reviews' "keep as written" lists are kept as written.

## Context

The KDE desktop Charles reaches for most is the Apple `container` flavor in
home-network (`scripts/desktop-kde.sh`, `HOST=local`): Debian 13, Plasma 6 on
X11, xrdp auto-login, PipeWire sound over the RDP channel, real arm64 Chrome
beside Firefox ESR, reached through the Windows App on localhost:3390. It is
cattle: an 80 s image build, a 3 s start, destroyed when idle.

Its one structural limit is that every host is GPU-less to the guest, which
pins it to X11, keeps KWin compositing off, and puts an RDP client and a
greeter between Charles and the desktop. home-network followups item 17
(2026-09-29) analysed try-omarchy (github.com/omacom/try-omarchy, MIT) as the
way around that: a patched QEMU 11.1.1 on Hypervisor.framework, virglrenderer
replaying guest OpenGL on the Apple GPU, Cocoa window with dynamic resolution
and HiDPI, free-page memory reclaim, tuned audio. It was declined for want of
a use case. Charles has now asked for it: "ostensibly the same thing but a
real VM using QEMU", with try-omarchy's performance and integration.

Decisions already taken (2026-10-02):

- New repo at `~/Projects/qemu` (the empty dir this session opened). The
  existing KDE files in home-network are not touched; home-network gets a
  pointer paragraph at the end.
- First version must include two-way clipboard, one shared Mac folder, and
  microphone in, on top of display, HiDPI resize, sound out, keyboard,
  trackpad scroll and pinch, network, and ssh.
- Plasma Wayland first, X11 session as the fallback.

What is on the M4 Pro today (verified this session): macOS 27.0.1, 14 cores,
48 GB, 678 GB free; Xcode 26 with Swift 6.4 and the CLT; Homebrew QEMU 11.1.1
(cocoa only, no GL, no virtio-gpu-gl: unusable for this); no meson or ninja
(their build script downloads pinned copies); brew edk2 firmware at
`/opt/homebrew/share/qemu/edk2-aarch64-code.fd`; `mkisofs` present;
Debian 13 `generic-arm64` cloud image available with SHA512SUMS; in trixie,
`eglinfo` is in `mesa-utils`, `kmscube` and `wl-clipboard` exist, Plasma is
6.3.6. try-omarchy tested their runtime on macOS 27.0.1 (M2 Pro,
2026-10-01), so the OS is not a risk. try-omarchy main is at 82927e9
(2026-10-03 UTC); the latest DMG (v0.4.1, 2026-09-15) predates the QEMU
11.1.1 runtime, so the DMG is not a shortcut for anything we want to measure.

## Definition of success **[rev 3]**

Not "Debian boots in QEMU". Plasma on this stack must be meaningfully better
than the xrdp container for interactive local use: GPU compositing, sharp
HiDPI, window resize that the desktop follows, Mac-feeling keyboard and
trackpad, sound and mic, idle overhead near their 10 to 15% of a core, and
a lifecycle as simple as the container's. A permanent llvmpipe desktop is
project failure, not a fallback.

## Design in one paragraph

Reuse three things from try-omarchy and nothing else: (1) the **runtime**
(QEMU + 23 patches + virgl + libslirp + ANGLE, built by their own
`build-qemu-gpu-runtime.sh` from a pinned checkout); (2) **[rev 2]** the
compiled **Swift helper** `omarchy-vm-helper`, whose bridge and query modes
run as standalone processes beside any QEMU (`--bridge-native-clipboard
QEMU_PID SOCKET`, `--host-audio-frequency output|input`, likewise audio,
camera, battery, timezone bridges), so the host half of the clipboard is
theirs, not ours; (3) **[rev 2]** the matching **guest agents** from
`guest/native-overlay/` that are distro-neutral Python over wl-clipboard and
pactl. Not reused: the Swift launcher app and its factory, boot-kit,
provenance and consent machinery; the Arch guest; anything Hyprland- or
Omarchy-specific. Build our **guest** the way `dell-labvm.sh` already builds
Debian 13 + Plasma on a real systemd: Debian cloud image + cloud-init NoCloud
seed, booted headless once to produce `factory.qcow2`, then run from a
throwaway qcow2 overlay so the VM stays cattle (factory = image, overlay =
container). One zsh **lifecycle script** with the house verbs.

```
Mac window (Cocoa, gl=on)  <-- virglrenderer <-- virtio-gpu-gl-pci <-- Mesa virgl <-- KWin Wayland
Mac speakers / mic         <-- SDL audiodev  <-- intel-hda + hda-micro      <-- PipeWire (systemd user)
NSPasteboard               <-- omarchy-vm-helper --bridge-native-clipboard <-- virtserialport <-- their clipboard agent (wl-clipboard)
~/kdevm-share              <-- virtio-9p (their guest_owner patch)          <-- /home/charles/Mac (own 10-line mount unit)
localhost:2222             <-- slirp hostfwd                                 <-- sshd
QMP unix socket            <-- down / status
fw_cfg opt/kdevm/*         <-- per-launch hints (scale)                     <-- first-login script
```

## Repo layout (`~/Projects/qemu`, git, no remote yet)

```
README.md                     what it is, the verbs, how it differs from desktop-kde-local
kdevm.sh                      lifecycle: runtime | factory | preflight | up | launch | down | destroy | rebuild | status | ssh | console
runtime/
  pin.txt                     try-omarchy commit (pinned; 82927e9 today)
  build.sh                    shallow-clone at the pin into a scratch dir, run their
                              macos/build-qemu-gpu-runtime.sh, then `swift build -c release`
                              in macos/ for omarchy-vm-helper; copy both to
                              ~/Artifacts/kdevm-runtime/<pin>/ and point `current` at it
guest/
  build.sh                    download + verify cloud image, render user-data, mkisofs seed,
                              headless boot, wait for cloud-init, kernel capability checks,
                              poweroff -> factory.qcow2
  user-data.yaml.tmpl         cloud-init (packages, write_files, runcmd); derived from
                              dell-labvm.sh's kde profile + desktop-kde/Dockerfile, minus xrdp
  files/                      sddm autologin, Firefox policies.json (copied from desktop-kde),
                              Chrome managed policy, kwalletrc, first-login scale script,
                              kdevm-display-sync (only if Phase 2 needs it), Mac share mount
                              unit, environment.d, PipeWire quantum conf (theirs)
  vendor/                     verbatim copies from try-omarchy guest/native-overlay with the
                              upstream path and commit in a header: clipboard agent, its user
                              unit and udev rule (later: audio agent, camera, battery)
docs/
  plan.md                     this file
  runbook.md                  the measured facts, provenance, the gotchas, the fallbacks taken
  patches.md                  one table: each of the 23 patches, what it does, kept (all are)
```

State outside the repo:

- `~/Artifacts/kdevm-runtime/<pin>/` the built runtime and helper (30+ min
  to remake; `~/Artifacts` is the house home for artifacts that are slow or
  impossible to regenerate and it is in Time Machine).
- `~/.cache/kdevm/` the cloud image, seed ISO, `factory.qcow2`, `work.qcow2`
  overlay, QMP and bridge sockets, serial log. Regenerable and large, and
  `~/.cache` is already a Time Machine exclusion. Cattle, by design.
- `~/kdevm-share/` the default shared folder (env `KDEVM_SHARE` overrides).

## Phases and milestones

### Phase 0: scaffold, runtime, helper (one sitting, mostly waiting on a compiler)

1. `git init` the repo, README, `.gitignore` (nothing big is ever committed).
   Copy this plan in as `docs/plan.md`.
2. `runtime/build.sh`: clone try-omarchy at the pin into the scratchpad, run
   `macos/build-qemu-gpu-runtime.sh` unchanged (it downloads checksum-pinned
   QEMU commit c3d48b7d, libslirp 4.9.4, virgl 1.3.0, meson, ninja, dtc,
   keycodemapdb, ANGLE and libepoxy bottles; applies all 23 patches; relocates
   and ad-hoc signs with the HVF entitlement). **[rev 2]** Then
   `swift build -c release` in `macos/` (Package.swift, tools 6.0, one
   executable target, no dependencies) and keep `omarchy-vm-helper`. Copy
   both to `~/Artifacts/kdevm-runtime/<pin>/`. Leave their build parallelism
   at default (14 cores); record wall time.
3. Smoke: `bin/qemu-system-aarch64 -device help | grep virtio-gpu-gl-pci`,
   `-display cocoa,gl=on` accepted, `-audiodev help` lists `sdl`, `-accel hvf`
   boots the Debian cloud image headless to a login prompt with the brew edk2
   firmware (their runtime manifest ships no `share/qemu`, so brew's firmware
   file is the one we use; it works with any QEMU). `omarchy-vm-helper
   --host-timezone` prints a zone and `--host-audio-frequency output` prints
   a rate (proves the helper runs outside an app bundle; `main.swift` only
   defaults to `--run-qemu` when its bundle path ends in `.app`).
4. **[rev 3]** Provenance block written to the runbook now, extended at each
   later phase: try-omarchy commit, QEMU commit and version, virgl, libslirp,
   ANGLE and epoxy versions, macOS version and build, Mac model, build wall
   time; later the Debian image file name and SHA512, guest kernel, Mesa,
   KWin and Plasma versions.

Milestone 0: a signed, GL-capable QEMU and a working helper on this Mac,
boot time and build time written in the runbook.

### Phase 1: factory image (headless, no GUI yet)

1. `guest/build.sh`: fetch `debian-13-generic-arm64.qcow2` (the **generic**
   image, not genericcloud: its full `linux-image-arm64` has virtio_gpu, DRM,
   snd-hda-intel, 9pnet_virtio and virtio-input; the cloud kernel does not).
   Verify against SHA512SUMS. Copy to `factory.qcow2`, `qemu-img resize` to
   40 GB (cloud-init growpart does the rest).
2. Render `user-data` from the template: user `charles` (groups include
   `render` and `video`, **[rev 4]**, so the DRM nodes are reachable from
   an ssh session during the preflight), sudo NOPASSWD
   (**[rev 3]** marked temporary in the file and the runbook: it is the
   container's convention and fine for a local cattle VM, but it bypasses PAM
   and so must go when Touch ID sudo is ever wired in), the ssh public key
   from `~/.ssh/id_ed25519.pub`, password from
   `~/projects/home-network/secrets/xrdp-desktop-pass.txt` (same password as
   every desktop in the house, for sddm and sudo). Packages: the dell-kde
   kde list minus xrdp/xorgxrdp (`kde-plasma-desktop plasma-workspace
   kwin-wayland sddm konsole dolphin systemsettings kde-cli-tools plasma-pa
   kscreen`), PipeWire trio, `firefox-esr`, Noto fonts, `xwayland`,
   `wl-clipboard` (for the clipboard agent), `mesa-utils` and `kmscube` (for
   the preflight), plus the workable-Linux tools line copied verbatim from
   `desktop-kde/Dockerfile`. runcmd installs Google's arm64 Chrome .deb
   exactly as the Dockerfile does.
3. write_files: sddm `[Autologin] User=charles Session=plasma`; Firefox
   `policies.json` (same file as the container); Chrome managed policy (same
   four keys) plus `First Run` sentinel and `mimeapps.list`; `kwalletrc` off;
   `kscreenlockerrc` autolock off; TZ America/New_York; environment.d with
   `ELECTRON_OZONE_PLATFORM_HINT=wayland` and `MOZ_ENABLE_WAYLAND=1`;
   **[rev 2]** their PipeWire quantum drop-in (4096, written for the
   emulated HDA's coarse DMA counter); **[rev 2]** the clipboard agent, its
   udev rule (port `dev.tryomarchy.clipboard`, group `users`) and its user
   unit, verbatim, enabled for `graphical-session.target`; the Mac share
   mount unit. KWin compositing stays ON this time (that is the point).
4. Seed ISO with `mkisofs -V cidata -J -r user-data meta-data`. Boot headless
   (`-display none`, serial to a log, `hostfwd` 2222) **[rev 4]** with its
   own throwaway copy of `edk2-arm-vars.fd` as the writable pflash, made in
   `~/.cache/kdevm/` for this boot and deleted with the seed afterwards; the
   Homebrew template is never attached writable by any kdevm boot, not only
   the Phase 2 one. Poll `ssh -p 2222 cloud-init status --wait`.
5. **[rev 3] Kernel capability checks, fatal to the build.** Over ssh:
   `modinfo` or `CONFIG_*=y` for virtio_gpu (CONFIG_DRM_VIRTIO_GPU),
   virtio_input, virtio_blk, virtio_net, virtio_rng, virtio_balloon with
   CONFIG_PAGE_REPORTING, 9p + 9pnet + 9pnet_virtio, snd_hda_intel, and
   **[rev 4]** the fw_cfg sysfs driver (CONFIG_FW_CFG_SYSFS as `y` or `m`,
   `modinfo qemu_fw_cfg` if modular) because the Phase 2 scale hint arrives
   through `/sys/firmware/qemu_fw_cfg/by_name/`; and
   `ls /usr/share/wayland-sessions /usr/share/xsessions` so the real session
   file names (`plasma.desktop`, `plasmax11.desktop` expected) go into the
   runbook and sddm's `Session=` is set from what is actually there. Record
   kernel, Mesa, KWin and Plasma versions. A finished factory is then known
   to carry a kernel that supports every device we attach.
6. `sudo poweroff`; delete the seed so the factory never re-runs cloud-init,
   and the provisioning boot's vars copy with it.

Milestone 1: `factory.qcow2` with Plasma and both browsers installed, ssh
works, kernel checks pass, build time measured (expect 8 to 12 min, dominated
by apt over the WAN). Rebuildable with one command.

### Phase 1.5: graphics preflight **[rev 3]** (before KWin ever touches the GPU)

`kdevm.sh preflight`: boot the overlay with the full Phase 2 device list and
the same private vars copy `up` uses (passing `systemd.unit=multi-user.target`
one-shot through grub is awkward under UEFI), then over ssh `sudo systemctl stop sddm` and run, as charles,
`id`, `ls -l /dev/dri`, `getfacl /dev/dri/card0 /dev/dri/renderD128`,
`eglinfo -B` (surfaceless and GBM platforms), and `kmscube -c 300` on
`/dev/dri/card0`, which draws 300 frames straight to the virtio scanout in
the Mac window. Pass criteria: a card and a render node exist, the renderer
string names virgl, no llvmpipe, EGL initialises, kmscube animates in the
Cocoa window at a steady rate. Then `systemctl start sddm`.

**[rev 4] Seat-ACL trap.** An ssh session does not own the local seat, so
once sddm is stopped `/dev/dri/card0` may refuse charles with permission
denied while the GPU stack is perfectly healthy. Provisioning puts charles
in the `render` and `video` groups (Phase 1) so the render node is always
reachable; if kmscube still cannot open the card from ssh, run it as
`sudo kmscube -c 300` and record that as a permission observation, not a
graphics failure. Failure classification, written into the runbook:

```
no /dev/dri                          kernel, device line, or QEMU
/dev/dri present, eglinfo llvmpipe   Mesa, virgl, or the renderer
virgl OK, kmscube only under sudo    seat ACL, not the GPU stack
virgl and kmscube OK, Plasma fails   KWin, KScreen, or the session
```

Milestone 1.5: software rendering ruled out before Plasma is involved.

### Phase 2: the window (the phase that decides the project)

1. `kdevm.sh up`: create `work.qcow2` as an overlay on the factory if absent,
   query the host sample rates with the helper, then launch:

   ```
   -machine virt,accel=hvf,gic-version=3   -cpu host,pmu=off
   -smp 4,sockets=1,cores=4,threads=1      -m 8192M   -nodefaults
   -drive if=pflash,format=raw,readonly=on,file=<edk2-aarch64-code.fd>
   -drive if=pflash,format=raw,file=<per-VM vars copy>
   -drive if=none,id=root,file=work.qcow2,format=qcow2,cache=writeback
   -device virtio-blk-pci,drive=root
   -device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080
   -display cocoa,gl=on,show-cursor=on,zoom-to-fit=on,full-screen=off,full-grab=on,immersive=off,swap-opt-cmd=off
   -device virtio-keyboard-pci  -device virtio-tablet-pci  -device virtio-pinch-pci
   -audiodev sdl,id=snd,timer-period=1000,out.buffer-count=8,out.frequency=<helper>,in.frequency=<helper>
   -device intel-hda  -device hda-micro,audiodev=snd
   -netdev user,id=net,hostfwd=tcp:127.0.0.1:2222-:22  -device virtio-net-pci,netdev=net
   -object rng-random,id=rng,filename=/dev/urandom  -device virtio-rng-pci,rng=rng
   -device virtio-balloon-pci,free-page-reporting=on
   -fw_cfg name=opt/kdevm/scale,string=<auto|2|1>
   -qmp unix:<sock>,server=on,wait=off   -serial file:<log>   -monitor none
   ```

   (`gic-version=3` is mandatory on their QEMU under HVF; their launcher
   rejects GICv2.) **[rev 4]** The UEFI variable store is a private copy per
   VM: `up` copies `/opt/homebrew/share/qemu/edk2-arm-vars.fd` (the template
   matching the code file we boot) to `~/.cache/kdevm/efivars.fd` when
   absent and attaches that copy as the writable pflash; the Homebrew
   template itself is never attached writable, and `destroy` removes the
   copy with the overlay. **[rev 3]** The audio line is theirs: `timer-period`,
   `out.buffer-count`, and `out.frequency`/`in.frequency` from
   `omarchy-vm-helper --host-audio-frequency output|input` (48000 if the
   query fails, as in their launcher); the deferred mic open and the HDA
   full-ring recovery are in the runtime already. The SDL device picker
   (their audio bridge) is a later item. Memory 8 GB because free-page
   reporting hands unused pages back to macOS; CPU 4 is their documented
   minimum. Both are env overridable like the container's. Per-launch hints
   travel by `fw_cfg` rather than kernel arguments because we boot through
   UEFI and grub, not a direct kernel; the guest reads them from
   `/sys/firmware/qemu_fw_cfg/by_name/opt/kdevm/`.
2. **[rev 3]** HiDPI policy: auto by default, `KDEVM_SCALE` overrides. First
   test whether Plasma 6.3 picks scale 2 on its own from the EDID the
   dynamic-display patch publishes. If not, the first-login script applies
   `kscreen-doctor output.Virtual-1.scale.<n>` once, where n is the fw_cfg
   value: `2` when the Mac's main display is Retina (read the same way
   `rdp-launch.sh` reads the pixel size), `1` otherwise, or the override.
3. Measure and record: Plasma Wayland comes up under sddm autologin; KWin's
   support information (`qdbus6 org.kde.KWin /KWin supportInformation`)
   names virgl; resizing the Mac window changes the guest mode; keyboard,
   trackpad, two-finger scroll, pinch in a browser (their `pinch-input.lua`
   only disabled tap-to-click and disable-while-typing on the pinch device
   for Hyprland; libinput under KWin may need the same via a per-device
   setting, test first); 60 s idle QEMU CPU and charged memory with their
   `scripts/profile-process.py` (stdlib Python, works as is; their figure is
   10 to 15% of one core, under 25% is accepted).
4. **[rev 3] Fallback ladder, in order; each rung is written down before the
   next is tried:**
   1. Plasma Wayland, dynamic EDID, KScreen follows the DRM hotplug by
      itself. Expected.
   2. Plasma Wayland plus a small `kdevm-display-sync`. **[rev 4]** The
      source of truth is the live EDID in sysfs, not KScreen's own mode
      list, because the helper only exists when KScreen's view may be
      stale: a udev rule on the drm `change` event (HOTPLUG=1) runs a
      script that reads `/sys/class/drm/card*-Virtual-*/edid`, decodes the
      preferred detailed timing to width, height and refresh (the one piece
      of their Hyprland helper worth borrowing, its EDID decoder, is plain
      Python), then looks for that mode in `kscreen-doctor -j` and selects
      it with `kscreen-doctor output.Virtual-1.mode.<id>`; only if the list
      truly lacks the timing does it add a custom mode first. KScreen still
      applies the final mode. Every transition is logged. About 60 lines.
   3. Plasma X11 (`Session=plasmax11`, add `kwin-x11`), compositing on,
      virgl still under it.
   4. Fixed backing resolution at the Mac's pixel size plus `zoom-to-fit`
      (the rdp-launch.sh trick). Last resort, loses live resize.
   5. llvmpipe as the everyday path: stop, this is failure; the container
      already does that better.

Milestone 2: Charles sees Plasma in a native Mac window, resizes it, types in
Konsole, and the idle number is in the runbook.

### Phase 3: browsers and sound (Charles's acceptance test)

1. Chrome: `chrome://gpu` shows hardware acceleration on virgl (their virgl
   patch exists precisely so browsers get ES 3 contexts without flags). If
   the renderer crashes on real pages, the fallback is a managed policy or
   `/etc/opt/chrome/policies` flag file disabling GPU compositing; record
   which happened. Firefox ESR: `about:support` compositing line.
   **[rev 3]** Record renderer status and video decode separately: GPU
   compositing and WebGL state, then video playback smoothness and QEMU CPU
   during a 1080p video. Video decode is CPU-only on this stack by design;
   smooth playback is the bar, hardware decode is not.
2. YouTube with sound in Chrome. **[rev 3]** Mic verified on its own, not
   inferred from output: `wpctl status` and `pactl list sources short` show
   the HDA source; `pw-record` 5 s then `pw-play`; a browser mic test. The
   first mic use triggers a macOS Microphone prompt for the QEMU binary
   (ad-hoc signed, so a rebuilt runtime re-prompts: noted).
3. Same bar as 2026-09-29: ten minutes of real use, several tabs, a video,
   sound, by Charles.

Milestone 3: "looks and runs great" or a list of what does not.

### Phase 4: clipboard and shared folder

1. Shared folder: `-fsdev local,id=share,path=$KDEVM_SHARE,security_model=none,
   guest_owner_uid=1000,guest_owner_gid=1000` (their 9p guest-owner patch) and
   `-device virtio-9p-pci,fsdev=share,mount_tag=mac`. Guest: our own systemd
   mount unit for `/home/charles/Mac`, `trans=virtio,version=9p2000.L,
   nofail`, written at factory build. **[rev 2]** Their 200-line
   `omarchy-native-mac-share` is not reused: it reads the folder name from
   the kernel command line and manages xdg-folder symlinks for Omarchy; a
   fixed `~/Mac` mount point needs none of that. **[rev 3]** Test the whole
   round trip: Mac creates, Debian reads and edits, Mac reads the edit;
   Debian creates, Mac sees charles as owner; rename and delete from each
   side. It is an exchange folder, not a build tree; say so in the README.
2. **[rev 2]** Clipboard: `-chardev socket,id=clip,path=<sock>,server=on,
   wait=off` + `-device virtio-serial-pci` + `virtserialport,chardev=clip,
   name=dev.tryomarchy.clipboard` (their port name, kept so the agent runs
   unmodified). `up` starts `omarchy-vm-helper --bridge-native-clipboard
   $qemu_pid <sock>` after QMP answers and restarts it if it exits while
   QEMU lives (their launcher does the same); it exits on its own when the
   QEMU pid is gone. Protocol is one JSON line per message, text and PNG,
   SHA-256 echo suppression, 16 MB cap, already implemented on both ends.
   Net new code: zero on the host, zero in the guest. (The review's point
   about PNG-extensible framing was aimed at rev 1's text-only bridge; rev 2
   made it moot.)
3. ssh verb: `kdevm.sh ssh` = `ssh -p 2222 -o StrictHostKeyChecking=accept-new charles@localhost`.

Milestone 4: copy a line and a screenshot each way; a file round-trips
through the share.

### Phase 5: lifecycle polish, docs, handoff

1. Verbs finished: `down` sends QMP `system_powerdown`, waits up to 30 s,
   then kills; `destroy` removes the overlay (and `--all` the factory and
   cloud image); `rebuild` = destroy overlay + new factory (fresh Chrome, the
   same reason the srv container is rebuilt); `console` tails the serial
   log; `launch` is `up` (the window is the session) so Lab Launcher's
   vocabulary still fits. **[rev 3]** `status` is the first diagnostic
   command and reports: runtime pin, factory age, QEMU pid and QMP state,
   bridge pids, port 2222, overlay path with apparent and allocated size,
   shared-folder path, configured vCPU and RAM, and, when ssh answers, guest
   kernel and session type (Wayland or X11).
2. **[rev 3]** Memory reclaim check, once, after the desktop is settled:
   charged footprint at idle via `profile-process.py`, then inside the guest
   allocate and touch 2 GB with Python, free it, wait 20 s, sample again.
   Expect a visible drop (their 3 GiB headless test returned about 95% of a
   768 MiB burst). Documented as a measurement, not a promise.
3. `docs/runbook.md`: the provenance block, measured build and boot times,
   idle CPU and memory from the profiler, every fallback rung reached, the
   privacy-prompt note, the GICv3 rule, the generic-vs-cloud kernel rule, the
   NOPASSWD note. **[rev 2]** `docs/patches.md`: the 23 patches in one table
   (what each does; all kept because the build script applies them as a set
   and every one is QEMU-, virgl- or slirp-level, none is Omarchy-specific;
   `cocoa-product-identity` and `cocoa-immersive-mode` are cosmetic and
   harmless). Documentation only, no patch surgery.
4. Commit. **[rev 3]** Hosting stays off the critical path: after Milestone
   3, offer the srv bare remote (`repos/qemu.git`, master, the house rule for
   a repo with no remote); nothing here is sensitive so GitHub would also do;
   Charles's call.
5. home-network: one paragraph in CLAUDE.md's desktop section and a closing
   note on followups item 17 pointing at `~/Projects/qemu`. Only after
   Milestone 3, and only those two edits. Lab Launcher row: offer, do not do.
6. Memory note under the qemu project: location of runtime and state, the
   verbs, the fallbacks taken.

## Future integration roadmap (not v1; the helper already has each bridge) **[rev 2, rev 3]**

Each is wiring, not writing, once Phase 4 is in. Ordered by value to Charles:

1. Audio device picker: `--bridge-native-audio` plus their guest
   `omarchy-native-audio-bridge` (pactl-based), so Plasma's sound applet
   lists the Mac's outputs and inputs and routes live.
2. Timezone mirroring: `--bridge-native-timezone`; the guest side hooks
   Omarchy menus, so a 10-line `timedatectl` receiver replaces it.
3. Camera: `--bridge-native-camera` plus `v4l2loopback-dkms` and their guest
   bridge; appears as a V4L2 device for browsers.
4. Battery: `--bridge-native-battery` plus their DKMS power_supply module;
   Plasma already reads UPower, so the widget just works. Only worth it if
   the M4 Pro is a laptop.
5. Touch ID sudo: `--bridge-native-authentication` plus their PAM broker;
   Debian side is pam config; requires removing NOPASSWD (see Phase 1).
6. USB passthrough (`qemu-xhci` + `usb-host`, patch included) and bridged
   networking (their socket_vmnet helper): only on a real use case; slirp is
   right for a local desktop.

## Honest comparison with the container (to put in the README)

| | desktop-kde-local (container) | kdevm (this) |
|---|---|---|
| Image / factory build | ~80 s | ~10 min (apt over WAN) |
| Start | ~3 s | ~15 to 25 s (UEFI, kernel, sddm) |
| Idle host CPU | near 0 | ~10 to 15% of a core (their number) |
| Memory | 6 GB cap | 8 GB nominal, unused pages returned to macOS |
| Session | X11, compositing off, RDP client, greeter | Wayland, GPU compositing, native window, no client |
| Sound | PipeWire over RDP channel, out only | HDA, out and mic |
| Clipboard | RDP, text | their bridge, text and PNG |
| Files | none | one shared Mac folder |
| Remote use | tailnet (srv flavor) | local only, by nature |

## Risks and the fallback for each

- KWin Wayland on virgl misbehaves: the Phase 2 ladder.
- Chrome renderer on virgl: disable GPU compositing by policy, note it.
- Their runtime ships no firmware: brew's edk2 file (confirmed from their
  runtime manifest; already planned).
- Debian kernel lacks a module: caught by the Phase 1 checks, not in Phase 2;
  fix is `linux-image-arm64` or a different base image.
- Pinch device not recognised by libinput as a touchpad: scroll still works;
  pinch becomes a documented limitation.
- **[rev 2]** Swift helper fails to build or its clipboard bridge misbehaves
  outside the app: fall back to the revision-1 plan, a stdlib Python
  `host/clipboard-bridge.py` speaking the same JSON-line protocol to the
  same guest agent (text only).
- Runtime build fails on macOS 27 SDK: their 2026-10-01 run was on 27.0.1, so
  unlikely; if it does, pin their build to the Sequoia SDK via
  `SDKROOT`, else fall back to a plain QEMU 11.1 build with
  `--enable-opengl --enable-virglrenderer` against brew libepoxy and lose the
  patches (still GL, still a window; worse idle and audio).
- Privacy prompts (mic, Accessibility for full-grab) re-ask after every
  runtime rebuild: accepted, documented.

## Verification (end to end, after Phase 5)

1. `kdevm.sh destroy --all && kdevm.sh factory` completes unattended, kernel
   checks pass, time recorded.
2. `kdevm.sh preflight` passes: virgl in `eglinfo`, kmscube animates.
3. `kdevm.sh up` opens a Mac window with Plasma logged in within 30 s;
   `kdevm.sh status` shows running, bridge alive, and 2222 answering.
4. KWin support information names virgl; `kscreen-doctor -o` shows the
   expected scale and the mode equals the window's backing-pixel size;
   drag-resize changes the mode (or the ladder rung reached is recorded).
5. Chrome plays a YouTube video with sound; `chrome://gpu` state and video
   CPU recorded; mic records and plays back.
6. Clipboard both ways, text and a PNG screenshot; file round trip through
   `~/kdevm-share` including rename and delete.
7. 60 s idle sample with `profile-process.py`: under 25% of one core;
   reclaim check shows the footprint drop.
8. `kdevm.sh down` powers off cleanly; `up` again resumes the same overlay
   with the session state; `rebuild` produces a new factory and the next
   `up` is fresh.

## Not in scope

Everything in the roadmap above, nested virtualization, 120 Hz work, a
signed app bundle, a Debian integration .deb (cloud-init write_files does
that job for one machine), the srv flavor (local only by nature), Lab
Launcher integration (offered, not done), any change to the existing
container recipe, any multi-distro ambition.
