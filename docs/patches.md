# The 35 runtime patches

All applied as a set by try-omarchy's `macos/build-qemu-gpu-runtime.sh` at the
pinned commit (v1.3.0, 13d63df); kdevm keeps every one. None is Omarchy- or
Arch-specific: they are QEMU, virglrenderer and libslirp changes. A few are
cosmetic for us and harmless, and one (the notch) is turned off by the
launcher. Descriptions condensed from the patch headers and the try-omarchy
README; the pinned sources are the authority. The first 23 came with the
original pin (82927e9, v0.5.1); the twelve marked "since v1.3.0" arrived
with the resync of 2026-11-02.

| patch | layer | what it does | matters to kdevm |
|---|---|---|---|
| virgl-native-opengl | virglrenderer | Drives Apple's OpenGL 4.1 core context directly (no ANGLE on the display path), keeps real multisample counts with a mutable-storage fallback, integer vertex attributes, single alpha/BGRA conversion. Lets browsers get the ES 3 contexts they need for default acceleration. | the GPU path itself |
| qemu-texture-borrowing-11.1 | QEMU display | Forward-port of the startergo render mega-patch trimmed to 18 files: Cocoa GL scanout borrows the guest texture instead of copying, dynamic display API changes for 11.1. Since v1.1.0 it carries kdevm's own fix (try-omarchy #312): `-display cocoa` without a graphics console no longer crashes. | the GPU path itself |
| qemu-gpu-spike-resolution-fix | QEMU display | Vendored kosmickrisp fix for GPU usage spikes on resolution change; also fixes a latched `gl_dirty` flag that made Cocoa re-render every refresh tick (idle 22% to 15% of a core). | idle CPU |
| qemu-darwin-gpu-fence-poll | QEMU display | Darwin fence polling for virtio-gpu so frame completion is observed without busy waiting. | idle CPU, smoothness |
| qemu-cocoa-dynamic-display | QEMU Cocoa | Window resize publishes the backing-pixel size and host refresh through the virtio-gpu EDID and raises a DRM hotplug in the guest. | live resize, HiDPI |
| qemu-cocoa-precise-scroll | QEMU Cocoa | Point-precise trackpad deltas carried as REL_WHEEL_HI_RES with legacy wheel events at 120-unit boundaries. | trackpad feel |
| qemu-cocoa-pinch-zoom | QEMU Cocoa + new device | `virtio-pinch-pci`: macOS magnification gestures become two synthetic contacts on a dedicated touchpad device. | pinch in browsers |
| qemu-cocoa-full-grab-focus | QEMU Cocoa | Command chords reach the guest as Super whenever the window is focused, not only while the mouse is grabbed (absolute pointing drops the grab). | Command as Meta |
| qemu-cocoa-full-grab-reenable | QEMU Cocoa | Re-enables the CGEventTap after macOS disables it on timeout or user input. | Command as Meta, reliability |
| qemu-cocoa-iso-section-grave-swap | QEMU Cocoa | Swaps KEY_GRAVE and KEY_102ND on ISO Apple keyboards when the launcher says `iso`. | no (ANSI keyboard); inert without the env |
| qemu-cocoa-injected-text | QEMU Cocoa | Remote-control tools' injected ASCII becomes paced guest key presses. | no, harmless |
| qemu-cocoa-immersive-mode | QEMU Cocoa | Separate `immersive=` option (hard-hidden menu bar and Dock) from full-screen. | cosmetic; we run `immersive=off` |
| qemu-cocoa-pause-ownership | QEMU Cocoa | Removes the Machine menu's Pause/Resume so only the helper can enter the paused state. | harmless |
| qemu-cocoa-product-identity | QEMU Cocoa | Process name, window title and application menu from QEMU's `-name`; the icon from `TRYOMARCHY_PRODUCT_ICON` or `TryOmarchy.icns` three directories above the binary. | the Dock and menu say kdevm (`-name kdevm`); before v1.1.0 the name was hard-coded and `runtime/build.sh` rewrote the patch |
| qemu-cocoa-no-app-nap (since v1.3.0) | QEMU Cocoa | Holds an NSProcessInfo activity for the whole run so macOS never naps QEMU when none of its windows can be seen (screen locked, full screen on another Space, minimized). A napped QEMU runs every thread, the vCPUs too, at background priority: 2 to 20 % of normal speed. `TRYOMARCHY_APP_NAP=1` leaves it out. | the VM keeps working out of sight |
| qemu-darwin-main-loop-qos (since v1.3.0) | QEMU main loop | The main-loop thread asks for user-interactive QoS so the HDA timers and virgl are not delayed 10 to 50 ms behind busy vCPUs and Mac work. `TRYOMARCHY_MAIN_LOOP_QOS=default` keeps the default. | audio crackle under load |
| qemu-hda-no-catch-up (since v1.3.0) | QEMU audio | After a main-loop stall (shader compiles, a busy Mac) the HDA output timer no longer takes all the missed guest audio at once; the debt is forgiven and QEMU's ring covers the stall. Codec property `pace`, on by default. | audio under load |
| qemu-sdl-audio-playback-thread (since v1.3.0) | QEMU audio | The playback device is opened and closed on helper threads; the big lock never waits for CoreAudio. A device that does not answer within 3 s leaves the VM running without sound, and is used when it comes back. | the VM never freezes on a slow audio device |
| qemu-sdl-audio-capture-thread (since v1.3.0) | QEMU audio | The recording device is opened on its own thread. A slow coreaudiod (a pending microphone permission) used to hold the big lock inside a vCPU for minutes, freezing the whole VM. | the microphone open never freezes the VM |
| qemu-cocoa-minimum-guest-size (since v1.3.0) | QEMU Cocoa | Offers the guest at least 800x600 points so a reboot in a small window does not leave EDK2's DEBUG console asserting (fewer than 25 rows) in a dead loop. | a guest reboot in a small window boots |
| qemu-cocoa-pointer-mapping (since v1.3.0) | QEMU Cocoa | The absolute pointer and the guest cursor use one ratio per axis in view coordinates; the window keeps its size and tells the guest, instead of being fitted to each guest mode. | cursor alignment, window size across boot stages |
| virgl-ctx0-upload-flush (since v1.3.0) | virglrenderer | Flushes context 0 after a host 2D upload (the firmware's text console), which Apple GL otherwise shows stale. | firmware and console display |
| qemu-cocoa-command-chord-hold (since v1.3.0) | QEMU Cocoa | Under full-grab, guest Super stays held for the whole Command chord; the event tap used to consume Command's flagsChanged and release Super before the chord key. | Command as Meta |
| qemu-cocoa-touch-scroll (since v1.3.0) | QEMU Cocoa + pinch device | Precise trackpad scrolling in the focused view drives two contacts on the pinch touchpad, so libinput reports finger scrolling and browsers recognise two-finger swipe back and forward. | swipe navigation in browsers |
| qemu-cocoa-notch (since v1.3.0) | QEMU Cocoa | Full screen on a MacBook with a camera housing uses the whole panel (one private AppKit lookup, checked against its signature), for a guest that knows where the housing is. | OFF: `kdevm.sh` sets `TRYOMARCHY_NOTCH=0`, Plasma has no notion of a cutout |
| qemu-cocoa-korean-caps-lock (since v1.3.0) | QEMU Cocoa | Caps Lock as the 한/영 key on a Mac with a Korean input source. | inert without one |
| qemu-hvf-free-page-reclaim | QEMU HVF | Handles virtio-balloon free-page reports under HVF: unmap, replace host backing with fresh anonymous memory, remap. Returns unused guest RAM to macOS. | memory |
| qemu-hvf-mapped-sections | QEMU HVF | Tracks which sections are mapped so ROMD transitions (pflash) and unaligned sections are not unmapped twice. | correctness with UEFI pflash |
| qemu-hda-full-ring-recovery | QEMU audio | A delayed audio callback no longer discards a full HDA ring; the producer clock is rebased and the ring drains. | audio dropouts |
| qemu-sdl-audio-device-selection | QEMU audio | SDL backend picks named output/input devices, defers the mic open until the guest records, closes it after. | sound, mic, privacy |
| qemu-9p-guest-owner | QEMU 9p | `guest_owner_uid/gid` on `-fsdev local` so the Mac user's files appear owned by the guest user. | shared folder |
| qemu-usb-host-exact-bus | QEMU USB | `usb-host` matches an exact bus and port. | not used in v1 |
| qemu-darwin-strchrnul-compat | QEMU build | `strchrnul` compatibility on Darwin SDKs. | builds at all |
| libslirp-darwin-icmp-matching | libslirp | ICMP echo reply matching on Darwin so `ping` works from the guest. | networking |
| libslirp-ipv4-udp-translation | libslirp | IPv4 UDP reply translation fixes. | networking (DNS, QUIC) |
