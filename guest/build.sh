#!/bin/zsh -f
# Build the kdevm factory image: Debian 13 generic arm64 cloud image + cloud-init
# (guest/user-data.yaml.tmpl) booted ONCE headless under the kdevm runtime, then
# checked and powered off. The result, ~/.cache/kdevm/factory.qcow2, is the
# "image"; kdevm.sh up runs a throwaway overlay on it (the "container").
#
#   guest/build.sh            build (refuses if factory.qcow2 exists; use rebuild)
#   guest/build.sh --force    replace an existing factory
#
# This is the direct entry point: it takes the lifecycle lock and runs the
# build function from guest/factory.zsh in this same process. kdevm.sh
# factory, rebuild and a first-run up call the same function while holding
# their own lock. Needs: the runtime (runtime/build.sh), mkisofs (brew
# cdrtools), Homebrew qemu (qemu-img and the edk2 firmware), an ssh public
# key. The guest password comes from KDEVM_PASS_FILE (default
# ~/.config/kdevm/password, generated on first use). Optional config:
# ~/.config/kdevm/env.
set -euo pipefail
umask 077   # disks, seed (holds the plaintext password), vars: owner-only from creation

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KDEVM_TOOL=guest/build.sh
source "$REPO/lib/kdevm-common.zsh"
kdevm_load_env
STATE="${KDEVM_STATE:-$HOME/.cache/kdevm}"
RT="${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current"
QEMU="$RT/bin/kdevm"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
FW_CODE="${KDEVM_FW_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
FW_VARS_TEMPLATE="${KDEVM_FW_VARS:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}"
USER_NAME="${KDEVM_USER:-$(id -un)}"
SSH_PORT="${KDEVM_SSH_PORT:-2222}"
FACTORY="$STATE/factory.qcow2"
KNOWN_HOSTS="$STATE/known_hosts"

source "$REPO/guest/factory.zsh"
trap kdevm_factory_cleanup EXIT   # script scope: covers the whole build
take_lock
kdevm_factory_build "${1:-}"
