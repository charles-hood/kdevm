# kdevm

The Debian 13 + KDE Plasma 6 desktop as a real VM on this Mac: QEMU on
Apple's Hypervisor.framework, the guest's OpenGL replayed on the Apple GPU
through VirGL, Plasma Wayland in a native, resizable, HiDPI Mac window. No
RDP client, no greeter.

It is the sibling of the Apple `container` desktop in home-network
(`scripts/desktop-kde-local.sh`) and uses the same Debian 13, the same two
browsers (native arm64 Google Chrome and Firefox ESR), the same password,
the same tools line. What it adds is a GPU.

The host runtime is [try-omarchy](https://github.com/omacom/try-omarchy)'s
patched QEMU 11.1.1 (23 patches: Cocoa dynamic display, VirGL on native
macOS OpenGL, HVF free-page memory reclaim, HDA audio recovery, precise
scroll and pinch, 9p ownership mapping, and more), built by their own script
from a pinned commit, plus their Swift helper for the clipboard bridge. The
guest is ours: a Debian cloud image provisioned once by cloud-init into a
factory image, run from a throwaway overlay. Factory = image, overlay =
container; the VM stays cattle.

## Verbs

```
kdevm.sh runtime     build/stage the QEMU runtime + helper   (~2 min, once)
kdevm.sh factory     build the Debian factory image           (~10 min)
kdevm.sh up          start the desktop (builds anything missing)
kdevm.sh preflight   up + graphics preflight over ssh, prints a verdict
kdevm.sh down        clean power-off (overlay state kept; up resumes it)
kdevm.sh destroy     drop the overlay (--all: factory and base image too)
kdevm.sh rebuild     new factory (fresh Chrome), new overlay
kdevm.sh status      the first diagnostic command
kdevm.sh ssh [cmd]   ssh charles@localhost:2222
kdevm.sh console     tail the guest serial log
```

Env: `KDEVM_CPUS` (4), `KDEVM_MEM_MB` (8192), `KDEVM_SCALE` (auto, 1, 2),
`KDEVM_SHARE` (`~/kdevm-share`, mounted at `~/Mac` in the guest),
`KDEVM_FULLSCREEN` (off).

## Where things live

| | |
|---|---|
| `~/Projects/qemu` | this repo: scripts, cloud-init template, vendored guest agents, docs. Nothing large. |
| `~/Artifacts/kdevm-runtime/<pin>/` | the built QEMU + helper (`current` symlink). In Time Machine. |
| `~/.cache/kdevm/` | base image, `factory.qcow2`, `work.qcow2`, UEFI vars copy, sockets, logs. Disposable. |
| `~/kdevm-share/` | the one folder shared with the guest. An exchange folder, not a build tree. |

## Compared with the container

| | desktop-kde-local (container) | kdevm (this) |
|---|---|---|
| Image / factory build | ~80 s | ~10 min (apt over WAN) |
| Start | ~3 s | UEFI, kernel, sddm: see runbook |
| Idle host CPU | near 0 | see runbook |
| Memory | 6 GB cap | 8 GB nominal, unused pages returned to macOS |
| Session | X11, compositing off, RDP client, greeter | Wayland, GPU compositing, native window |
| Sound | PipeWire over RDP channel, out only | HDA, out and mic |
| Clipboard | RDP, text | try-omarchy bridge, text and PNG |
| Files | none | one shared Mac folder |
| Remote use | tailnet (srv flavor) | local only, by nature |

Measured numbers, provenance, fallbacks taken and gotchas: `docs/runbook.md`.
The plan this was built from: `docs/plan.md`. The 23 runtime patches and
what each does: `docs/patches.md`.
