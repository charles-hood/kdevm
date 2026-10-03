#!/bin/zsh
# Build the kdevm factory image: Debian 13 generic arm64 cloud image + cloud-init
# (guest/user-data.yaml.tmpl) booted ONCE headless under the kdevm runtime, then
# checked and powered off. The result, ~/.cache/kdevm/factory.qcow2, is the
# "image"; kdevm.sh up runs a throwaway overlay on it (the "container").
#
#   guest/build.sh            build (refuses if factory.qcow2 exists; use rebuild)
#   guest/build.sh --force    replace an existing factory
#
# Needs: the runtime (runtime/build.sh), mkisofs (brew cdrtools), Homebrew
# qemu (qemu-img and the edk2 firmware), an ssh public key. The guest
# password comes from KDEVM_PASS_FILE (default ~/.config/kdevm/password,
# generated on first use). Optional config: ~/.config/kdevm/env.
set -euo pipefail
umask 077   # disks, seed (holds the plaintext password), vars: owner-only from creation

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# ~/.config/kdevm/env holds defaults; an explicit environment variable wins.
# Only KDEVM_* assignments are read; values may reference $HOME.
kdevm_load_env() {
  local f="$HOME/.config/kdevm/env" line k v; [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ '^[[:space:]]*(export[[:space:]]+)?(KDEVM_[A-Z_]+)=(.*)$' ]] || continue
    k="${match[2]}"; v="${match[3]}"
    [[ -n "${(P)k:-}" ]] && continue
    eval "export $k=$v"
  done < "$f"
}
kdevm_load_env
STATE="${KDEVM_STATE:-$HOME/.cache/kdevm}"
RT="${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current"
QEMU="$RT/bin/qemu-system-aarch64"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
FW_CODE="${KDEVM_FW_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
FW_VARS_TEMPLATE="${KDEVM_FW_VARS:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}"
IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/latest
IMAGE=debian-13-generic-arm64.qcow2
USER_NAME="${KDEVM_USER:-$(id -un)}"
PASS_FILE="${KDEVM_PASS_FILE:-$HOME/.config/kdevm/password}"
SSH_PUB="${KDEVM_SSH_PUB:-}"
if [[ -z "$SSH_PUB" ]]; then
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    [[ -f "$k" ]] && { SSH_PUB="$k"; break; }
  done
fi
SSH_PORT="${KDEVM_SSH_PORT:-2222}"
DISK_GB="${KDEVM_DISK_GB:-40}"
FACTORY="$STATE/factory.qcow2"
INFO="$STATE/factory-info.txt"
KNOWN_HOSTS="$STATE/known_hosts"
SSH_OPTS=(-p "$SSH_PORT" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=no
          -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)

die() { echo "guest/build.sh: $*" >&2; exit 1; }
log() { echo "== $(date +%H:%M:%S) $*"; }

[[ -x "$QEMU" ]] || die "runtime missing at $RT; run runtime/build.sh first"
[[ -x "$QEMU_IMG" ]] || die "qemu-img missing (brew install qemu)"
command -v mkisofs >/dev/null || die "mkisofs missing (brew install cdrtools)"
[[ -f "$FW_CODE" && -f "$FW_VARS_TEMPLATE" ]] || die "edk2 firmware missing at $FW_CODE / $FW_VARS_TEMPLATE"
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "KDEVM_USER must be a plain lowercase unix name: $USER_NAME"
if [[ ! -f "$PASS_FILE" ]]; then
  # The guest user's password (sddm and sudo are passwordless anyway; this is
  # for the lock screen and `su`). Generated once, kept private. Python, not a
  # tr|head pipeline: under pipefail that pipeline exits 141 (SIGPIPE).
  install -d -m 700 "$(dirname "$PASS_FILE")"
  python3 -c 'import secrets, string, sys; sys.stdout.write("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))' > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "generated a guest password at $PASS_FILE (set KDEVM_PASS_FILE to use your own)"
fi
chmod 600 "$PASS_FILE" 2>/dev/null || true
[[ -n "$SSH_PUB" && -f "$SSH_PUB" ]] || die "no ssh public key found; set KDEVM_SSH_PUB or run ssh-keygen -t ed25519"
if [[ -f "$FACTORY" && "${1:-}" != --force ]]; then
  die "$FACTORY exists; use 'kdevm.sh rebuild' or --force"
fi
# An overlay keeps cluster references into the factory it was created on;
# replacing the factory underneath it corrupts the guest. rebuild drops the
# overlay first; a direct --force must not.
[[ -f "$STATE/work.qcow2" ]] && die "an overlay ($STATE/work.qcow2) still backs the current factory; use 'kdevm.sh rebuild' (drops it) or 'kdevm.sh destroy' first"
pgrep -qf "file=$STATE/(factory|work).qcow2" && die "a kdevm VM is running; 'kdevm.sh down' first"

install -d -m 700 "$STATE"; chmod 700 "$STATE"
# One lock per state directory, shared with kdevm.sh (which sets KDEVM_LOCKED
# when it already holds it). mkdir is atomic; a dead holder's lock is reclaimed.
LOCK="$STATE/lock"
if [[ "${KDEVM_LOCKED:-}" != 1 ]]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    holder=$(cat "$LOCK/pid" 2>/dev/null || echo 0)
    kill -0 "$holder" 2>/dev/null && die "another kdevm command is running (pid $holder)"
    rm -rf "$LOCK"; mkdir "$LOCK" || die "cannot take the lock $LOCK"
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
fi
t0=$(date +%s)

# ---- 1. base image, verified ------------------------------------------------
if [[ ! -f "$STATE/$IMAGE" ]]; then
  log "downloading $IMAGE"
  curl -sSL -o "$STATE/SHA512SUMS" "$IMAGE_URL/SHA512SUMS"
  curl -sSL -o "$STATE/$IMAGE.part" "$IMAGE_URL/$IMAGE"
  mv "$STATE/$IMAGE.part" "$STATE/$IMAGE"
fi
( cd "$STATE" && grep " $IMAGE\$" SHA512SUMS | shasum -a 512 -c - >/dev/null ) || die "$IMAGE failed SHA512 check"
IMAGE_SHA=$(grep " $IMAGE\$" "$STATE/SHA512SUMS" | cut -c1-16)
log "base image $IMAGE (sha512 $IMAGE_SHA...) verified"

# ---- 2. factory disk --------------------------------------------------------
WORK="$FACTORY.building"
rm -f "$WORK"
cp "$STATE/$IMAGE" "$WORK"
"$QEMU_IMG" resize -q "$WORK" "${DISK_GB}G"

# ---- 3. cloud-init seed -----------------------------------------------------
SEED_DIR="$STATE/seed"; rm -rf "$SEED_DIR"; mkdir -p "$SEED_DIR"
# Literal token replacement (no sed: a password with & or | must survive).
V="$REPO/guest/vendor"
KDEVM_USER_NAME="$USER_NAME" KDEVM_PASS="$(tr -d '\n' < "$PASS_FILE")" KDEVM_SSHKEY="$(tr -d '\n' < "$SSH_PUB")" \
python3 - "$REPO/guest/user-data.yaml.tmpl" "$SEED_DIR/user-data" \
  "$V/omarchy-native-clipboard-bridge" "$V/omarchy-native-clipboard-bridge.service" \
  "$V/92-omarchy-native-clipboard.rules" "$V/90-try-omarchy-quantum.conf" \
  "$REPO/guest/files/firefox-policies.json" <<'PY'
import base64, json, os, sys
tmpl, out, agent, unit, udev, quantum, firefox = sys.argv[1:]
b64 = lambda p: base64.b64encode(open(p, "rb").read()).decode()
text = open(tmpl).read()
for k, v in {
    "@@USER@@": os.environ["KDEVM_USER_NAME"],
    # JSON strings are valid YAML double-quoted scalars: any password survives
    # (&, |, #, a leading digit, quotes, backslashes).
    "@@PASS@@": json.dumps(os.environ["KDEVM_PASS"]),
    "@@SSHKEY@@": json.dumps(os.environ["KDEVM_SSHKEY"]),
    "@@B64_CLIPBOARD_AGENT@@": b64(agent),
    "@@B64_CLIPBOARD_UNIT@@": b64(unit),
    "@@B64_CLIPBOARD_UDEV@@": b64(udev),
    "@@B64_PIPEWIRE_QUANTUM@@": b64(quantum),
    "@@B64_FIREFOX_POLICIES@@": b64(firefox),
}.items():
    text = text.replace(k, v)
open(out, "w").write(text)
PY
grep -q '@@' "$SEED_DIR/user-data" && die "unrendered token in user-data"
printf 'instance-id: kdevm-factory-%s\nlocal-hostname: kdevm\n' "$(date +%Y%m%d%H%M%S)" > "$SEED_DIR/meta-data"
mkisofs -quiet -V cidata -J -r -o "$STATE/seed.iso" "$SEED_DIR/user-data" "$SEED_DIR/meta-data"

# ---- 4. headless provisioning boot -----------------------------------------
# Private, throwaway UEFI variable store for THIS boot: the Homebrew template
# is never attached writable by any kdevm boot.
PROV_VARS="$STATE/provision-vars.fd"
cp "$FW_VARS_TEMPLATE" "$PROV_VARS"
SERIAL="$STATE/factory-serial.log"; : > "$SERIAL"
rm -f "$KNOWN_HOSTS"
log "booting headless for provisioning (serial: $SERIAL)"
"$QEMU" \
  -machine virt,accel=hvf,gic-version=3 -cpu host,pmu=off \
  -smp 4,sockets=1,cores=4,threads=1 -m 6144M -nodefaults \
  -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
  -drive if=pflash,format=raw,file="$PROV_VARS" \
  -drive if=none,id=root,file="$WORK",format=qcow2,cache=writeback \
  -device virtio-blk-pci,drive=root \
  -drive if=none,id=seed,file="$STATE/seed.iso",format=raw,readonly=on \
  -device virtio-blk-pci,drive=seed \
  -netdev user,id=net,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 -device virtio-net-pci,netdev=net,romfile= \
  -object rng-random,id=rng,filename=/dev/urandom -device virtio-rng-pci,rng=rng \
  -display none -serial "file:$SERIAL" -monitor none &
# romfile= : the runtime ships no option ROMs (no share/qemu), and the guest
# boots from UEFI + disk, so no device needs one (try-omarchy does the same).
QPID=$!
# On any failure after boot: keep the disk for inspection as factory.qcow2.failed
# (owner-only), remove the seed (it holds the plaintext password) and the vars.
trap 'kill $QPID 2>/dev/null; sleep 1; mv -f "$WORK" "$FACTORY.failed" 2>/dev/null; rm -f "$PROV_VARS" "$STATE/seed.iso"; rm -rf "$SEED_DIR"; [[ "${KDEVM_LOCKED:-}" == 1 ]] || rm -rf "$LOCK"' EXIT

# ---- 5. wait for ssh, then for cloud-init -----------------------------------
log "waiting for ssh on localhost:$SSH_PORT"
for i in {1..120}; do
  ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" true 2>/dev/null && break
  kill -0 $QPID 2>/dev/null || die "QEMU exited during provisioning; see $SERIAL"
  sleep 5
done
ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" true || die "ssh never answered; see $SERIAL"
log "ssh up after $(( $(date +%s) - t0 )) s; waiting for cloud-init (apt over the WAN, several minutes)"
# cloud-init status exits 0 (done), 2 (done with warnings: "degraded"), 1 (error).
CI_RC=0
ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" 'sudo cloud-init status --wait --long' || CI_RC=$?
if [[ $CI_RC -eq 2 ]]; then
  echo "cloud-init finished DEGRADED (warnings above); continuing, the checks below decide"
elif [[ $CI_RC -ne 0 ]]; then
  true
fi
[[ $CI_RC -eq 0 || $CI_RC -eq 2 ]] || {
  # Keep the evidence on the host: the whole cloud-init output, plus the apt
  # error lines up front. The half-built disk is kept too (factory.qcow2.failed).
  ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" 'sudo cat /var/log/cloud-init-output.log' > "$STATE/cloud-init-output.log" 2>/dev/null || true
  echo "---- apt/dpkg errors (full log: $STATE/cloud-init-output.log):"
  grep -E '^(E:|W:|dpkg:|Err:)|Unable to locate|no installation candidate|unmet dependencies|not going to be installed|Depends:' "$STATE/cloud-init-output.log" | grep -v '^\.' | head -40
  die "cloud-init reported an error (disk kept at $FACTORY.failed)"
}
t1=$(date +%s)
log "cloud-init done at $((t1 - t0)) s"

# ---- 6. kernel capability checks (fatal) and provenance ---------------------
log "kernel capability checks"
CHECKS=$(ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" 'bash -s' <<'EOF'
set -u
# Check the NEWEST installed kernel (package_upgrade may have installed one
# the factory will boot next time), not necessarily the running one. Full
# path to modinfo: a non-root ssh PATH on Debian lacks /usr/sbin.
krel=$(ls -1 /lib/modules | sort -V | tail -1)
cfg=/boot/config-$krel
echo "checking kernel $krel (running: $(uname -r))"
fail=0
has() { # module name, CONFIG symbol
  if /usr/sbin/modinfo -k "$krel" -n "$1" >/dev/null 2>&1; then echo "ok   $1 (module)"
  elif grep -q -E "^$2=(y|m)" "$cfg" 2>/dev/null; then echo "ok   $1 ($2=$(grep -E "^$2=" "$cfg" | cut -d= -f2))"
  else echo "FAIL $1 ($2 absent)"; fail=1; fi
}
has virtio_gpu     CONFIG_DRM_VIRTIO_GPU
has virtio_input   CONFIG_VIRTIO_INPUT
has virtio_blk     CONFIG_VIRTIO_BLK
has virtio_net     CONFIG_VIRTIO_NET
has virtio-rng     CONFIG_HW_RANDOM_VIRTIO
has virtio_balloon CONFIG_VIRTIO_BALLOON
has 9p             CONFIG_9P_FS
has 9pnet          CONFIG_NET_9P
has 9pnet_virtio   CONFIG_NET_9P_VIRTIO
has snd_hda_intel  CONFIG_SND_HDA_INTEL
has qemu_fw_cfg    CONFIG_FW_CFG_SYSFS
if grep -q '^CONFIG_PAGE_REPORTING=y' "$cfg"; then echo "ok   free-page reporting (CONFIG_PAGE_REPORTING)"; else echo "FAIL CONFIG_PAGE_REPORTING"; fail=1; fi
echo "sessions wayland: $(ls /usr/share/wayland-sessions 2>/dev/null | tr '\n' ' ')"
echo "sessions x11:     $(ls /usr/share/xsessions 2>/dev/null | tr '\n' ' ')"
ls /usr/share/wayland-sessions/plasma.desktop >/dev/null 2>&1 || { echo "FAIL plasma.desktop wayland session missing"; fail=1; }
echo "kernel:  $krel"
echo "mesa:    $(dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null)"
echo "kwin:    $(dpkg-query -W -f='${Version}' kwin-wayland 2>/dev/null)"
echo "plasma:  $(dpkg-query -W -f='${Version}' plasma-workspace 2>/dev/null)"
echo "chrome:  $(google-chrome --version 2>/dev/null)"
echo "firefox: $(firefox-esr --version 2>/dev/null)"
echo "sddm:    $(dpkg-query -W -f='${Version}' sddm 2>/dev/null)"
exit $fail
EOF
) && CHECK_RC=0 || CHECK_RC=$?
echo "$CHECKS"
[[ $CHECK_RC -eq 0 ]] || die "kernel capability checks failed; factory NOT produced (disk kept at $FACTORY.failed)"

{
  echo "factory built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "base image: $IMAGE sha512 $(grep " $IMAGE\$" "$STATE/SHA512SUMS" | cut -d' ' -f1)"
  echo "runtime: $(readlink "$RT" 2>/dev/null || echo "$RT")"
  echo "$CHECKS"
} > "$INFO"

# ---- 7. power off, finalize --------------------------------------------------
log "powering off"
ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" 'sudo cloud-init clean --logs; sync; sudo poweroff' 2>/dev/null || true
for i in {1..60}; do kill -0 $QPID 2>/dev/null || break; sleep 1; done
kill -0 $QPID 2>/dev/null && { echo "QEMU still up after 60 s; killing" >&2; kill $QPID; sleep 1; }
trap - EXIT; [[ "${KDEVM_LOCKED:-}" == 1 ]] || trap 'rm -rf "$LOCK"' EXIT
rm -f "$PROV_VARS" "$STATE/seed.iso" "$KNOWN_HOSTS"; rm -rf "$SEED_DIR"
mv "$WORK" "$FACTORY"; chmod 600 "$FACTORY"
t2=$(date +%s)
echo "factory time: $((t2 - t0)) s (ssh up at $(( t1 - t0 )) s incl. cloud-init)" >> "$INFO"
log "factory ready: $FACTORY ($(du -h "$FACTORY" | cut -f1) on disk) in $((t2 - t0)) s"
