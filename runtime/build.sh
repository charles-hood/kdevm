#!/bin/zsh
# Build the host runtime kdevm runs on: try-omarchy's patched QEMU (HVF +
# Cocoa/VirGL + SLIRP + SDL duplex audio + virtio-9p) and its Swift helper
# (omarchy-vm-helper), whose bridge modes run standalone beside our QEMU.
#
# We run THEIR build script unchanged from a checkout pinned in pin.txt; it
# downloads checksum-pinned sources (QEMU 11.1.1 commit c3d48b7d, libslirp,
# virglrenderer, meson, ninja, dtc, keycodemapdb, ANGLE and libepoxy
# bottles), applies all 23 patches, relocates the dylibs and ad-hoc signs
# with the HVF entitlement. Then `swift build` produces the helper.
#
# Output: ~/Artifacts/kdevm-runtime/<pin>/{bin,lib,provenance.txt} and a
# `current` symlink. ~/Artifacts is the house home for artifacts that are
# slow to regenerate (this one is 30+ minutes).
#
#   runtime/build.sh            build (skips if <pin> already staged)
#   runtime/build.sh --force    rebuild even if staged
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$(tr -d '[:space:]' < "$REPO/runtime/pin.txt")"
SCRATCH="${KDEVM_SCRATCH:-$HOME/.cache/kdevm/build}"
SRC="$SCRATCH/try-omarchy"
DEST_ROOT="${KDEVM_RUNTIME_ROOT:-$HOME/Artifacts/kdevm-runtime}"
DEST="$DEST_ROOT/$PIN"
UPSTREAM=https://github.com/omacom/try-omarchy

if [[ -x "$DEST/bin/qemu-system-aarch64" && -x "$DEST/bin/omarchy-vm-helper" && "${1:-}" != --force ]]; then
  echo "runtime $PIN already staged at $DEST (use --force to rebuild)"; exit 0
fi

t0=$(date +%s)
echo "== checkout try-omarchy @ $PIN"
mkdir -p "$SCRATCH" "$DEST_ROOT"
if [[ ! -d "$SRC/.git" ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM"
fi
git -C "$SRC" fetch -q --depth 1 origin "$PIN"
git -C "$SRC" checkout -q --detach FETCH_HEAD
git -C "$SRC" clean -qfd -e .build -e macos/.build

echo "== build QEMU/VirGL runtime (their script, unchanged)"
( cd "$SRC" && bash macos/build-qemu-gpu-runtime.sh )
t1=$(date +%s)
echo "== runtime built in $((t1 - t0)) s"

echo "== build omarchy-vm-helper"
( cd "$SRC/macos" && swift build -c release --product omarchy-vm-helper 2>&1 | tail -3 )
HELPER="$SRC/macos/.build/release/omarchy-vm-helper"
[[ -x "$HELPER" ]] || { echo "helper not built at $HELPER" >&2; exit 1; }
t2=$(date +%s)
echo "== helper built in $((t2 - t1)) s"

echo "== stage to $DEST"
rm -rf "$DEST.staging"
ditto "$SRC/macos/.build/qemu-gpu-runtime" "$DEST.staging"
install -m 0755 "$HELPER" "$DEST.staging/bin/omarchy-vm-helper"
{
  echo "try-omarchy commit: $PIN"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "runtime build: $((t1 - t0)) s; helper build: $((t2 - t1)) s"
  grep -E '^(qemu_commit|qemu_version|slirp_version|virgl_version|virgl_tap_version|angle_version|epoxy_version|meson_root|ninja_version)=' \
    "$SRC/macos/build-qemu-gpu-runtime.sh" || true
  echo "qemu --version: $("$DEST.staging/bin/qemu-system-aarch64" --version | head -1)"
} > "$DEST.staging/provenance.txt"
rm -rf "$DEST"
mv "$DEST.staging" "$DEST"
ln -sfn "$DEST" "$DEST_ROOT/current"
cat "$DEST/provenance.txt"
echo "== done: $DEST_ROOT/current -> $DEST"
