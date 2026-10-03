# kdevm factory build, as a function. Sourced (zsh) by guest/build.sh and by
# kdevm.sh; the caller holds the lifecycle lock (take_lock) and calls
# kdevm_factory_build in the SAME process, so the mutation of shared state
# is done by the process that owns the advisory lock: if that process dies,
# the build dies with it and the kernel releases the lock. There is no
# delegated builder and no inherited "I am locked" marker.
#
# Caller provides (see guest/build.sh for the defaults): REPO STATE RT QEMU
# QEMU_IMG FW_CODE FW_VARS_TEMPLATE USER_NAME SSH_PORT FACTORY KNOWN_HOSTS,
# the library (die, take_lock, launch_tracked, stop_tracked, KDEVM_LOCK_FD)
# and `trap kdevm_factory_cleanup EXIT` at script scope.

flog() { echo "== $(date +%H:%M:%S) $*"; }

# Undo everything this build did after it started (F_OWNED=1): stop the
# provisioning VM (through its record, like any other stop), keep a
# half-built disk as factory.qcow2.failed (owner-only),
# remove the seed (plaintext password) and the vars copy. Each step is
# non-fatal so one failing step (an already-exited QEMU) cannot skip the rest.
# Before the build starts it touches nothing.
F_REC=""; F_PAT=""; F_WORK=""; F_PROV_VARS=""; F_SEED_DIR=""; F_OWNED=0
# Is the provisioning QEMU that F_REC vouches for alive? (No record, a dead
# process, another process under that pid, or one that cannot be inspected: no.)
kdevm_factory_vm_alive() {
  local PF_PID PF_START
  [[ -n "$F_REC" ]] && read_pidfile "$F_REC" && [[ "$(pid_state "$PF_PID" "$PF_START" "$F_PAT")" == running ]]
}
kdevm_factory_cleanup() {
  set +e
  if [[ $F_OWNED -eq 1 ]]; then
    # The seed holds the plaintext password and goes in every case. The disk
    # and the vars copy are touched only once the provisioning VM is
    # confirmed gone: one that could not be verified may still have them open.
    rm -f "$STATE/seed.iso" 2>/dev/null
    if [[ -z "$F_REC" ]] || stop_tracked "$F_REC" "$F_PAT" "provisioning QEMU" kill; then
      [[ -n "$F_WORK" && -f "$F_WORK" ]] && mv -f "$F_WORK" "$FACTORY.failed" 2>/dev/null
      rm -f "$F_PROV_VARS" 2>/dev/null
    else
      echo "the provisioning QEMU could not be confirmed stopped; $F_WORK and $F_PROV_VARS are left in place" >&2
    fi
    [[ -n "$F_SEED_DIR" ]] && rm -rf "$F_SEED_DIR"
  fi
  return 0
}

# The ssh public key the factory installs in the guest: KDEVM_SSH_PUB, or the
# first default key that exists. Prints its path; fails when there is none.
kdevm_ssh_pub() {
  local k="${KDEVM_SSH_PUB:-}"
  if [[ -z "$k" ]]; then
    for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do [[ -f "$k" ]] && break; done
  fi
  [[ -f "$k" ]] && print -r -- "$k"
}
# kdevm.sh asks this before it builds a runtime, so a first-time user without
# a key is told at once and not after the two-minute build.
kdevm_require_ssh_pub() { kdevm_ssh_pub >/dev/null || die "no ssh public key found; set KDEVM_SSH_PUB or run ssh-keygen -t ed25519"; }

kdevm_factory_build() {   # [--force]
  local force="${1:-}"
  [[ -n "${KDEVM_LOCK_FD:-}" ]] || die "internal error: kdevm_factory_build called without the lifecycle lock"

  local IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/latest
  local IMAGE=debian-13-generic-arm64.qcow2
  local PASS_FILE="${KDEVM_PASS_FILE:-$HOME/.config/kdevm/password}"
  local SSH_PUB
  local DISK_GB="${KDEVM_DISK_GB:-40}"
  local INFO="$STATE/factory-info.txt"
  local F_SERIAL="$STATE/factory-serial.log"
  local -a FSSH
  FSSH=(-p "$SSH_PORT" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=no
        -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
  local t0 t1 t2 i IMAGE_SHA V CI_RC CHECKS CHECK_RC

  [[ -x "$QEMU" ]] || die "runtime missing at $RT; run runtime/build.sh first"
  [[ -x "$QEMU_IMG" ]] || die "qemu-img missing (brew install qemu)"
  command -v mkisofs >/dev/null || die "mkisofs missing (brew install cdrtools)"
  [[ -f "$FW_CODE" && -f "$FW_VARS_TEMPLATE" ]] || die "edk2 firmware missing at $FW_CODE / $FW_VARS_TEMPLATE"
  [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "KDEVM_USER must be a plain lowercase unix name: $USER_NAME"
  if [[ ! -f "$PASS_FILE" ]]; then
    # The guest user's password (sddm and sudo are passwordless anyway; this
    # is for the lock screen and `su`). Generated once, kept private. Python,
    # not a tr|head pipeline: under pipefail that pipeline exits 141 (SIGPIPE).
    install -d -m 700 "$(dirname "$PASS_FILE")"
    python3 -c 'import secrets, string, sys; sys.stdout.write("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))' > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    echo "generated a guest password at $PASS_FILE (set KDEVM_PASS_FILE to use your own)"
  fi
  chmod 600 "$PASS_FILE" 2>/dev/null || true
  kdevm_require_ssh_pub; SSH_PUB="$(kdevm_ssh_pub)"
  install -d -m 700 "$STATE"; chmod 700 "$STATE"

  # Guards, under the lock (a concurrent command cannot change the answer).
  if [[ -f "$FACTORY" && "$force" != --force ]]; then
    die "$FACTORY exists; use 'kdevm.sh rebuild' or --force"
  fi
  # An overlay keeps cluster references into the factory it was created on;
  # replacing the factory underneath it corrupts the guest. rebuild drops the
  # overlay first; a direct --force must not.
  [[ -f "$STATE/work.qcow2" ]] && die "an overlay ($STATE/work.qcow2) still backs the current factory; use 'kdevm.sh rebuild' (drops it) or 'kdevm.sh destroy' first"
  pgrep -qf "file=$STATE/(factory|work).qcow2" && die "a kdevm VM is running; 'kdevm.sh down' first"
  # A provisioning VM that an earlier, killed build left behind and that the
  # guard above did not see is stopped through its record before its disk is
  # replaced below.
  F_WORK="$FACTORY.building"; F_REC="$STATE/factory-qemu.pid"; F_PAT="*${(b)QEMU}*file=${(b)F_WORK}*"
  stop_tracked "$F_REC" "$F_PAT" "provisioning QEMU" kill || die "a provisioning QEMU from an earlier build could not be stopped; see $F_REC"
  F_OWNED=1
  t0=$(date +%s)

  # ---- 1. base image, verified ----------------------------------------------
  if [[ ! -f "$STATE/$IMAGE" ]]; then
    [[ "${KDEVM_OFFLINE:-}" == 1 ]] && die "base image download requested while KDEVM_OFFLINE=1; refusing network access"
    flog "downloading $IMAGE"
    curl -sSL -o "$STATE/SHA512SUMS" "$IMAGE_URL/SHA512SUMS"
    curl -sSL -o "$STATE/$IMAGE.part" "$IMAGE_URL/$IMAGE"
    mv "$STATE/$IMAGE.part" "$STATE/$IMAGE"
  fi
  ( cd "$STATE" && grep " $IMAGE\$" SHA512SUMS | shasum -a 512 -c - >/dev/null ) || die "$IMAGE failed SHA512 check"
  IMAGE_SHA=$(grep " $IMAGE\$" "$STATE/SHA512SUMS" | cut -c1-16)
  flog "base image $IMAGE (sha512 $IMAGE_SHA...) verified"

  # ---- 2. factory disk ------------------------------------------------------
  rm -f "$F_WORK"
  cp "$STATE/$IMAGE" "$F_WORK"
  "$QEMU_IMG" resize -q "$F_WORK" "${DISK_GB}G"

  # ---- 3. cloud-init seed ---------------------------------------------------
  F_SEED_DIR="$STATE/seed"; rm -rf "$F_SEED_DIR"; mkdir -p "$F_SEED_DIR"
  # Literal token replacement (no sed: a password with & or | must survive).
  KDEVM_USER_NAME="$USER_NAME" KDEVM_PASS="$(tr -d '\n' < "$PASS_FILE")" KDEVM_SSHKEY="$(tr -d '\n' < "$SSH_PUB")" \
  python3 - "$REPO/guest/user-data.yaml.tmpl" "$F_SEED_DIR/user-data" "$REPO/guest" <<'PY'
import base64, json, os, re, sys
tmpl, out, guest = sys.argv[1:]
def scalar(value):
    # A JSON string is a valid YAML double-quoted scalar: any password
    # survives (&, |, #, a leading digit, quotes, backslashes).
    # ensure_ascii=False: raw UTF-8 is valid inside a YAML double-quoted
    # scalar, while JSON's \ud83d\udd11 surrogate pairs are not (PyYAML
    # returns two surrogates for an emoji and the guest cannot encode them).
    # What json.dumps leaves raw but YAML does not accept or does not keep
    # (DEL, the C1 controls, the Unicode line and paragraph separators) is
    # written as an escape, which both read back as the same character.
    return re.sub("[\x7f-\x9f\u2028\u2029\ufffe\uffff]", lambda m: "\\u%04x" % ord(m.group()), json.dumps(value, ensure_ascii=False))
values = {
    "USER": os.environ["KDEVM_USER_NAME"],
    "PASS": scalar(os.environ["KDEVM_PASS"]),
    "SSHKEY": scalar(os.environ["KDEVM_SSHKEY"]),
}
TOKEN = r"@@(B64:[A-Za-z0-9._/-]+|USER|PASS|SSHKEY)@@"
def expand(match):
    name = match.group(1)
    if name.startswith("B64:"):   # inline that file under guest/, base64
        return base64.b64encode(open(os.path.join(guest, name[4:]), "rb").read()).decode()
    return values[name]
text = open(tmpl, encoding="utf-8").read()
unknown = [t for t in re.findall(r"@@[^@\n]*@@", text) if not re.fullmatch(TOKEN, t)]
if unknown:
    sys.exit(f"unknown token in the template: {unknown[0]}")
# ONE pass over the template. What a token expands to is never scanned again,
# so nothing in a password, a key, a user name or an inlined file can be
# taken for a token.
open(out, "w", encoding="utf-8").write(re.sub(TOKEN, expand, text))
PY
  printf 'instance-id: kdevm-factory-%s\nlocal-hostname: kdevm\n' "$(date +%Y%m%d%H%M%S)" > "$F_SEED_DIR/meta-data"
  mkisofs -quiet -V cidata -J -r -o "$STATE/seed.iso" "$F_SEED_DIR/user-data" "$F_SEED_DIR/meta-data"

  # ---- 4. headless provisioning boot ---------------------------------------
  # Private, throwaway UEFI variable store for THIS boot: the Homebrew
  # template is never attached writable by any kdevm boot. The lock
  # descriptor is closed for the child (the lock is per process anyway).
  # romfile= : the runtime ships no option ROMs and the guest boots from
  # UEFI + disk, so no device needs one (try-omarchy does the same).
  F_PROV_VARS="$STATE/provision-vars.fd"
  cp "$FW_VARS_TEMPLATE" "$F_PROV_VARS"
  : > "$F_SERIAL"
  rm -f "$KNOWN_HOSTS"
  flog "booting headless for provisioning (serial: $F_SERIAL)"
  launch_tracked "$F_REC" "$STATE/factory-qemu.out" "$QEMU" \
    -machine virt,accel=hvf,gic-version=3 -cpu host,pmu=off \
    -smp 4,sockets=1,cores=4,threads=1 -m 6144M -nodefaults \
    -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
    -drive if=pflash,format=raw,file="$F_PROV_VARS" \
    -drive if=none,id=root,file="$F_WORK",format=qcow2,cache=writeback \
    -device virtio-blk-pci,drive=root \
    -drive if=none,id=seed,file="$STATE/seed.iso",format=raw,readonly=on \
    -device virtio-blk-pci,drive=seed \
    -netdev user,id=net,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 -device virtio-net-pci,netdev=net,romfile= \
    -object rng-random,id=rng,filename=/dev/urandom -device virtio-rng-pci,rng=rng \
    -display none -serial "file:$F_SERIAL" -monitor none \
    || die "$F_REC is in the way; the provisioning VM was not started"
  for i in {1..50}; do kdevm_factory_vm_alive && break; sleep 0.1; done
  # Not registered in time: cancel the launch so it cannot start later, behind this build's back.
  kdevm_factory_vm_alive || cancel_launch "$F_REC" || true

  # ---- 5. wait for ssh, then for cloud-init ---------------------------------
  flog "waiting for ssh on localhost:$SSH_PORT"
  for i in {1..120}; do
    ssh "${FSSH[@]}" "$USER_NAME@localhost" true 2>/dev/null && break
    kdevm_factory_vm_alive || die "QEMU exited during provisioning; see $F_SERIAL and $STATE/factory-qemu.out"
    sleep 5
  done
  ssh "${FSSH[@]}" "$USER_NAME@localhost" true || die "ssh never answered; see $F_SERIAL"
  flog "ssh up after $(( $(date +%s) - t0 )) s; waiting for cloud-init (apt over the WAN, several minutes)"
  # cloud-init status exits 0 (done), 2 (done with warnings: "degraded"), 1 (error).
  CI_RC=0
  ssh "${FSSH[@]}" "$USER_NAME@localhost" 'sudo cloud-init status --wait --long' || CI_RC=$?
  [[ $CI_RC -eq 2 ]] && echo "cloud-init finished DEGRADED (warnings above); continuing, the checks below decide"
  [[ $CI_RC -eq 0 || $CI_RC -eq 2 ]] || {
    # Keep the evidence on the host: the whole cloud-init output, plus the apt
    # error lines up front. The half-built disk is kept too (factory.qcow2.failed).
    ssh "${FSSH[@]}" "$USER_NAME@localhost" 'sudo cat /var/log/cloud-init-output.log' > "$STATE/cloud-init-output.log" 2>/dev/null || true
    echo "---- apt/dpkg errors (full log: $STATE/cloud-init-output.log):"
    grep -E '^(E:|W:|dpkg:|Err:)|Unable to locate|no installation candidate|unmet dependencies|not going to be installed|Depends:' "$STATE/cloud-init-output.log" | grep -v '^\.' | head -40
    die "cloud-init reported an error (disk kept at $FACTORY.failed)"
  }
  t1=$(date +%s)
  flog "cloud-init done at $((t1 - t0)) s"

  # ---- 6. kernel capability checks (fatal) and provenance -------------------
  flog "kernel capability checks"
  CHECKS=$(ssh "${FSSH[@]}" "$USER_NAME@localhost" 'bash -s' <<'EOF'
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
# the battery module is ours to build (DKMS, guest/vendor/try-omarchy-battery)
if /usr/sbin/modinfo -k "$krel" -n try_omarchy_battery >/dev/null 2>&1; then echo "ok   try_omarchy_battery (DKMS)"; else echo "FAIL try_omarchy_battery (DKMS did not build it for $krel)"; fail=1; fi
# nothing in the guest may act on the mirrored battery, and the guest may not sleep
if grep -qx 'CriticalPowerAction=Ignore' /etc/UPower/UPower.conf && grep -qx 'AllowRiskyCriticalPowerAction=true' /etc/UPower/UPower.conf; then echo "ok   UPower critical action: Ignore"; else echo "FAIL UPower would act on a critical battery ($(grep -E '^(CriticalPowerAction|AllowRisky)' /etc/UPower/UPower.conf | tr '\n' ' '))"; fail=1; fi
if [ "$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend 2>/dev/null)" = 's "no"' ]; then echo "ok   sleep disabled (logind CanSuspend=no)"; else echo "FAIL the guest can sleep (logind CanSuspend is not no)"; fail=1; fi
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

  # ---- 7. power off, finalize ----------------------------------------------
  flog "powering off"
  ssh "${FSSH[@]}" "$USER_NAME@localhost" 'sudo cloud-init clean --logs; sync; sudo poweroff' 2>/dev/null || true
  for i in {1..60}; do kdevm_factory_vm_alive || break; sleep 1; done
  kdevm_factory_vm_alive && echo "QEMU still up after 60 s; stopping it" >&2
  # Gone already (the record is dropped) or ended now by verified signals. A
  # provisioning VM that cannot be confirmed stopped still has the disk open:
  # no factory is produced from it.
  stop_tracked "$F_REC" "$F_PAT" "provisioning QEMU" kill || die "the provisioning QEMU could not be confirmed stopped; factory NOT produced"
  F_REC=""
  rm -f "$F_PROV_VARS" "$STATE/seed.iso" "$KNOWN_HOSTS"; rm -rf "$F_SEED_DIR"
  mv "$F_WORK" "$FACTORY"; chmod 600 "$FACTORY"   # cleanup finds no F_WORK afterwards
  t2=$(date +%s)
  echo "factory time: $((t2 - t0)) s (ssh up at $(( t1 - t0 )) s incl. cloud-init)" >> "$INFO"
  flog "factory ready: $FACTORY ($(du -h "$FACTORY" | cut -f1) on disk) in $((t2 - t0)) s"
}
