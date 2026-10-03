# Third-party notices

kdevm is a thin set of scripts. Almost everything that runs is someone else's
work, pulled in at build time from pinned sources. Nothing from the list
below is redistributed by this repository except the four small guest files
under `guest/vendor/` (MIT, see there).

| component | what kdevm uses | license | where it comes from |
|---|---|---|---|
| [try-omarchy](https://github.com/omacom/try-omarchy) | the QEMU/VirGL/libslirp build script and its 23 patches, the Swift helper (`omarchy-vm-helper`, clipboard and time zone bridges), four guest files vendored verbatim | MIT | cloned at the commit in `runtime/pin.txt`; vendored files carry their upstream path in `guest/vendor/README.md` |
| [QEMU](https://www.qemu.org/) | `qemu-system-aarch64` 11.1.1 built from source by try-omarchy's script, staged as `bin/kdevm`, run under HVF | GPL-2.0-only (with LGPL and BSD parts) | gitlab.com/qemu-project, commit pinned in try-omarchy's script |
| [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer) | the host-side OpenGL replay, built from source with the startergo patch set | MIT | pinned by try-omarchy's script |
| [libslirp](https://gitlab.freedesktop.org/slirp/libslirp) | user-mode networking | BSD-3-Clause | pinned by try-omarchy's script |
| ANGLE, libepoxy | GL dispatch and compatibility libraries in the runtime | BSD-3-Clause, MIT | startergo Homebrew bottles pinned by try-omarchy's script |
| [EDK II](https://github.com/tianocore/edk2) (`edk2-aarch64-code.fd`, `edk2-arm-vars.fd`) | UEFI firmware for the guest | BSD-2-Clause-Patent | the Homebrew `qemu` package on the host |
| `qemu-img` | overlay creation and resize | GPL-2.0 | the Homebrew `qemu` package on the host |
| [Debian](https://www.debian.org/) 13 generic arm64 cloud image | the guest base, verified against the published SHA512SUMS | DFSG-free; see the image's own licenses | cloud.debian.org, downloaded at factory build |
| KDE Plasma 6, KWin, PipeWire, Firefox ESR, Mesa and the rest of the guest package set | installed by apt inside the guest | their respective free licenses | Debian 13 archive |
| Google Chrome (arm64 .deb) | installed inside the guest at factory build | [Google Chrome Terms of Service](https://www.google.com/chrome/terms/) | dl.google.com, downloaded at factory build; you accept Google's terms by building the factory |
| `profile-process.py` (try-omarchy) | used by hand for the measurements in `docs/runbook.md`; not part of kdevm | MIT | try-omarchy checkout |

The patch set is described in `docs/patches.md`. kdevm modifies exactly one
patch at build time, `qemu-cocoa-product-identity.patch`, replacing the
product name string; the modified patch is regenerated from the pinned
upstream file on every build and is not stored here.

The QEMU binary kdevm builds is GPL-2.0 software. This repository does not
distribute it; if you distribute a built runtime, QEMU's license terms apply
to that distribution.
