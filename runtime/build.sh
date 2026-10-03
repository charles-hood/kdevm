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
# Output: $KDEVM_RUNTIME_ROOT/<pin>/{bin,lib,provenance.txt} and a `current`
# symlink; default ~/.local/share/kdevm/runtime. About two minutes on an
# M4 Pro. Optional config: ~/.config/kdevm/env.
#
# QEMU is staged as bin/kdevm, the way try-omarchy's app build stages it as
# "Try Omarchy": a bare executable has no bundle, so macOS labels it (Dock,
# Force Quit, crash reports) with its file name. Their helper only attaches
# to a process with that name or a qemu-system-* one, so the same rebrand is
# applied to that one line of the helper.
#
#   runtime/build.sh            build (skips if <pin> already staged)
#   runtime/build.sh --force    rebuild even if staged
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KDEVM_TOOL=runtime/build.sh
source "$REPO/lib/kdevm-common.zsh"
kdevm_load_env
PIN="$(tr -d '[:space:]' < "$REPO/runtime/pin.txt")"
SCRATCH="${KDEVM_SCRATCH:-${KDEVM_STATE:-$HOME/.cache/kdevm}/build}"
SRC="$SCRATCH/try-omarchy"
DEST_ROOT="${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}"
DEST="$DEST_ROOT/$PIN"
UPSTREAM=https://github.com/omacom/try-omarchy

# One build at a time per scratch checkout and per runtime root: a second
# build would revert the first one's rebrand edits under its compiler, or
# stage over it. The locks are inherited by everything this build starts
# (take_tree_lock), so a compiler left running by a killed build still
# holds them.
mkdir -p "$SCRATCH" "$DEST_ROOT"
for lockfile in "$DEST_ROOT/build.lock" "$SCRATCH/build.lock"; do
  take_tree_lock "$lockfile" || die "another runtime build is running, or its compilers still are ($lockfile is held); wait for them"
done

if [[ -x "$DEST/bin/kdevm" && -x "$DEST/bin/omarchy-vm-helper" && "${1:-}" != --force ]]; then
  echo "runtime $PIN already staged at $DEST (use --force to rebuild)"; exit 0
fi
# KDEVM_OFFLINE=1 (set by tests/checks.sh) must never reach a fetch or a build.
[[ "${KDEVM_OFFLINE:-}" == 1 ]] && die "runtime build requested while KDEVM_OFFLINE=1; refusing to fetch or build anything"

t0=$(date +%s)
echo "== checkout try-omarchy @ $PIN"
if [[ ! -d "$SRC/.git" ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM"
fi
git -C "$SRC" fetch -q --depth 1 origin "$PIN"
git -C "$SRC" checkout -q -- . 2>/dev/null || true     # drop last build's rebrand edits
git -C "$SRC" checkout -q --detach FETCH_HEAD
git -C "$SRC" clean -qfd -e .build -e macos/.build

# The one change to their tree is the product name, in two places. The Cocoa
# product-identity patch hard-codes "Try Omarchy" as the process name and in
# the application menu (About, Hide, Quit, the quit alert): rebrand the patch
# to "kdevm" and update the SHA-256 their build script checks it against. The
# helper's bridges accept a target whose executable is named "Try Omarchy":
# that name becomes "kdevm" too. Everything else is applied as is.
echo "== rebrand the product-identity patch: Try Omarchy -> kdevm"
PATCH="$SRC/macos/patches/qemu-cocoa-product-identity.patch"
sed -i '' 's/Try Omarchy/kdevm/g' "$PATCH"
NEWSHA=$(shasum -a 256 "$PATCH" | awk '{print $1}')
sed -i '' "s/^identity_patch_sha256=.*/identity_patch_sha256=$NEWSHA/" "$SRC/macos/build-qemu-gpu-runtime.sh"
grep -q "^identity_patch_sha256=$NEWSHA" "$SRC/macos/build-qemu-gpu-runtime.sh" || { echo "could not pin the rebranded patch hash" >&2; exit 1; }
IDENTITY="$SRC/macos/Sources/OmarchyVMHelper/FocusedCommandSuperBridge.swift"
sed -i '' 's/name == "Try Omarchy"/name == "kdevm"/' "$IDENTITY"
grep -q 'name == "kdevm"' "$IDENTITY" || { echo "could not rebrand the process name the helper accepts ($IDENTITY)" >&2; exit 1; }

echo "== build QEMU/VirGL runtime (their script, otherwise unchanged)"
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
mv "$DEST.staging/bin/qemu-system-aarch64" "$DEST.staging/bin/kdevm"
install -m 0755 "$HELPER" "$DEST.staging/bin/omarchy-vm-helper"
{
  echo "try-omarchy commit: $PIN"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "runtime build: $((t1 - t0)) s; helper build: $((t2 - t1)) s"
  grep -E '^(qemu_commit|qemu_version|slirp_version|virgl_version|virgl_tap_version|angle_version|epoxy_version|meson_root|ninja_version)=' \
    "$SRC/macos/build-qemu-gpu-runtime.sh" || true
  echo "qemu --version: $("$DEST.staging/bin/kdevm" --version | head -1)"
} > "$DEST.staging/provenance.txt"
rm -rf "$DEST"
mv "$DEST.staging" "$DEST"
ln -sfn "$DEST" "$DEST_ROOT/current"
cat "$DEST/provenance.txt"
echo "== done: $DEST_ROOT/current -> $DEST"
