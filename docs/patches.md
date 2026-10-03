# The 23 runtime patches

All applied as a set by try-omarchy's `macos/build-qemu-gpu-runtime.sh` at the
pinned commit; kdevm keeps every one. None is Omarchy- or Arch-specific: they
are QEMU, virglrenderer and libslirp changes. Two are cosmetic for us and
harmless. Descriptions condensed from the patch headers and the try-omarchy
README; the pinned sources are the authority.

| patch | layer | what it does | matters to kdevm |
|---|---|---|---|
| virgl-native-opengl | virglrenderer | Drives Apple's OpenGL 4.1 core context directly (no ANGLE on the display path), keeps real multisample counts with a mutable-storage fallback, integer vertex attributes, single alpha/BGRA conversion. Lets browsers get the ES 3 contexts they need for default acceleration. | the GPU path itself |
| qemu-texture-borrowing-11.1 | QEMU display | Forward-port of the startergo render mega-patch trimmed to 18 files: Cocoa GL scanout borrows the guest texture instead of copying, dynamic display API changes for 11.1. | the GPU path itself |
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
| qemu-cocoa-product-identity | QEMU Cocoa | Process name, icon and menu title from the enclosing app bundle. | cosmetic; outside a bundle it shows QEMU's own |
| qemu-hvf-free-page-reclaim | QEMU HVF | Handles virtio-balloon free-page reports under HVF: unmap, replace host backing with fresh anonymous memory, remap. Returns unused guest RAM to macOS. | memory |
| qemu-hvf-mapped-sections | QEMU HVF | Tracks which sections are mapped so ROMD transitions (pflash) and unaligned sections are not unmapped twice. | correctness with UEFI pflash |
| qemu-hda-full-ring-recovery | QEMU audio | A delayed audio callback no longer discards a full HDA ring; the producer clock is rebased and the ring drains. | audio dropouts |
| qemu-sdl-audio-device-selection | QEMU audio | SDL backend picks named output/input devices, defers the mic open until the guest records, closes it after. | sound, mic, privacy |
| qemu-9p-guest-owner | QEMU 9p | `guest_owner_uid/gid` on `-fsdev local` so the Mac user's files appear owned by the guest user. | shared folder |
| qemu-usb-host-exact-bus | QEMU USB | `usb-host` matches an exact bus and port. | not used in v1 |
| qemu-darwin-strchrnul-compat | QEMU build | `strchrnul` compatibility on Darwin SDKs. | builds at all |
| libslirp-darwin-icmp-matching | libslirp | ICMP echo reply matching on Darwin so `ping` works from the guest. | networking |
| libslirp-ipv4-udp-translation | libslirp | IPv4 UDP reply translation fixes. | networking (DNS, QUIC) |
