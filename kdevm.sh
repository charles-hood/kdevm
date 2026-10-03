#!/bin/zsh
# kdevm: the Debian 13 + KDE Plasma desktop as a GPU-accelerated QEMU VM on
# this Mac, in a native window. Runtime: try-omarchy's patched QEMU (HVF,
# Cocoa + VirGL, SLIRP, SDL duplex audio, virtio-9p) and its Swift helper for
# the clipboard bridge. Guest: our own Debian factory (guest/build.sh).
#
#   kdevm.sh runtime     build/stage the QEMU runtime + helper (~/Artifacts/kdevm-runtime)
#   kdevm.sh factory     build the Debian factory image (~/.cache/kdevm/factory.qcow2)
#   kdevm.sh up          start the desktop (overlay on the factory; builds what is missing)
#   kdevm.sh launch      same as up (the window IS the session; Lab Launcher vocabulary)
#   kdevm.sh preflight   up + the graphics preflight over ssh (eglinfo, kmscube), prints a verdict
#   kdevm.sh down        clean power-off via QMP (overlay state kept; up resumes it)
#   kdevm.sh destroy     remove the overlay and vars store (--all: also factory + base image)
#   kdevm.sh rebuild     destroy the overlay and rebuild the factory (fresh Chrome)
#   kdevm.sh status      the first diagnostic command
#   kdevm.sh ssh [cmd]   ssh into the guest on localhost:2222
#   kdevm.sh console     tail the guest serial log
#
# Env: KDEVM_CPUS (4) KDEVM_MEM_MB (8192) KDEVM_SCALE (auto|1|2) KDEVM_SHARE
# (~/kdevm-share) KDEVM_FULLSCREEN (off). Everything large lives outside the
# repo: runtime in ~/Artifacts, images/sockets/logs in ~/.cache/kdevm.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
STATE="${KDEVM_STATE:-$HOME/.cache/kdevm}"
RT="${KDEVM_RUNTIME:-$HOME/Artifacts/kdevm-runtime/current}"
QEMU="$RT/bin/qemu-system-aarch64"
HELPER="$RT/bin/omarchy-vm-helper"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
FW_CODE="${KDEVM_FW_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
FW_VARS_TEMPLATE="${KDEVM_FW_VARS:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}"
USER_NAME="${KDEVM_USER:-charles}"
SSH_PORT="${KDEVM_SSH_PORT:-2222}"
CPUS="${KDEVM_CPUS:-4}"
MEM_MB="${KDEVM_MEM_MB:-8192}"
SHARE="${KDEVM_SHARE:-$HOME/kdevm-share}"
FULLSCREEN="${KDEVM_FULLSCREEN:-off}"

FACTORY="$STATE/factory.qcow2"
WORK="$STATE/work.qcow2"
EFIVARS="$STATE/efivars.fd"
QMP="$STATE/qmp.sock"
CLIP="$STATE/clipboard.sock"
SERIAL="$STATE/serial.log"
PIDFILE="$STATE/qemu.pid"
BRIDGEPID="$STATE/clipboard-bridge.pid"
KNOWN_HOSTS="$STATE/known_hosts"
SSH_OPTS=(-p "$SSH_PORT" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=no
          -o LogLevel=ERROR -o ConnectTimeout=5)

die() { echo "kdevm: $*" >&2; exit 1; }
log() { echo "== $*"; }

qemu_pid() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && cat "$PIDFILE" || true; }
running() { [[ -n "$(qemu_pid)" ]]; }

# QMP: one command, stdlib Python over the unix socket.
qmp() {
  python3 - "$QMP" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()                                   # greeting
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
f.write(json.dumps({"execute": sys.argv[2]}) + "\n"); f.flush()
for line in f:
    d = json.loads(line)
    if "return" in d or "error" in d:
        print(json.dumps(d.get("return", d.get("error")))); break
PY
}

# Scale hint for the guest: auto = 2 on a Retina main display, 1 otherwise.
scale_hint() {
  case "${KDEVM_SCALE:-auto}" in
    auto) system_profiler SPDisplaysDataType 2>/dev/null | grep -q -i retina && echo 2 || echo 1 ;;
    *) echo "$KDEVM_SCALE" ;;
  esac
}

ensure_runtime() { [[ -x "$QEMU" && -x "$HELPER" ]] || { log "runtime missing; building"; "$REPO/runtime/build.sh"; }; }
ensure_factory() { [[ -f "$FACTORY" ]] || { log "factory missing; building (about 10 min)"; "$REPO/guest/build.sh"; }; }

up() {
  ensure_runtime; ensure_factory
  if running; then log "already running (pid $(qemu_pid))"; return 0; fi
  mkdir -p "$STATE" "$SHARE"
  [[ -f "$WORK" ]] || { log "new overlay on the factory"; "$QEMU_IMG" create -q -f qcow2 -b "$FACTORY" -F qcow2 "$WORK"; }
  # Private UEFI variable store: a copy of the template, never the template.
  [[ -f "$EFIVARS" ]] || cp "$FW_VARS_TEMPLATE" "$EFIVARS"
  rm -f "$QMP" "$CLIP"
  local out_hz in_hz scale
  out_hz=$("$HELPER" --host-audio-frequency output 2>/dev/null || echo 48000)
  in_hz=$("$HELPER" --host-audio-frequency input 2>/dev/null || echo 48000)
  scale=$(scale_hint)
  log "starting: $CPUS vCPU, ${MEM_MB} MB, scale hint $scale, audio ${out_hz}/${in_hz} Hz, share $SHARE"
  # gic-version=3 is mandatory on this QEMU under HVF. --shm-size's analogue
  # is not needed: a VM has its own /dev/shm.
  "$QEMU" \
    -machine virt,accel=hvf,gic-version=3 -cpu host,pmu=off \
    -smp "$CPUS,sockets=1,cores=$CPUS,threads=1" -m "${MEM_MB}M" -nodefaults \
    -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
    -drive if=pflash,format=raw,file="$EFIVARS" \
    -drive if=none,id=root,file="$WORK",format=qcow2,cache=writeback \
    -device virtio-blk-pci,drive=root \
    -device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080 \
    -display "cocoa,gl=on,show-cursor=on,zoom-to-fit=on,full-screen=$FULLSCREEN,full-grab=on,immersive=off,swap-opt-cmd=off" \
    -device virtio-keyboard-pci -device virtio-tablet-pci -device virtio-pinch-pci \
    -audiodev "sdl,id=snd,timer-period=1000,out.buffer-count=8,out.frequency=$out_hz,in.frequency=$in_hz" \
    -device intel-hda -device hda-micro,audiodev=snd \
    -netdev "user,id=net,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net \
    -object rng-random,id=rng,filename=/dev/urandom -device virtio-rng-pci,rng=rng \
    -device virtio-balloon-pci,free-page-reporting=on \
    -fsdev "local,id=share,path=$SHARE,security_model=none,guest_owner_uid=1000,guest_owner_gid=1000" \
    -device virtio-9p-pci,fsdev=share,mount_tag=mac \
    -device virtio-serial-pci,id=vser \
    -chardev "socket,id=clip,path=$CLIP,server=on,wait=off" \
    -device virtserialport,bus=vser.0,nr=2,chardev=clip,name=dev.tryomarchy.clipboard \
    -fw_cfg "name=opt/kdevm/scale,string=$scale" \
    -qmp "unix:$QMP,server=on,wait=off" -serial "file:$SERIAL" -monitor none \
    >"$STATE/qemu.out" 2>&1 &
  echo $! > "$PIDFILE"
  local pid=$!
  for i in {1..100}; do [[ -S "$QMP" && -S "$CLIP" ]] && break; kill -0 $pid 2>/dev/null || { cat "$STATE/qemu.out" >&2; die "QEMU exited at start"; }; sleep 0.1; done
  # Clipboard bridge: their helper, supervised while QEMU lives (as their launcher does).
  ( while kill -0 $pid 2>/dev/null; do
      "$HELPER" --bridge-native-clipboard "$pid" "$CLIP" >>"$STATE/clipboard-bridge.log" 2>&1 || true
      kill -0 $pid 2>/dev/null && sleep 1
    done ) &
  echo $! > "$BRIDGEPID"
  disown 2>/dev/null || true
  log "up: pid $pid, window open; ssh with: kdevm.sh ssh"
}

down() {
  running || { log "not running"; return 0; }
  local pid; pid=$(qemu_pid)
  log "power-off via QMP"
  qmp system_powerdown >/dev/null 2>&1 || true
  for i in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then log "guest did not power off in 30 s; terminating"; kill "$pid"; sleep 2; kill -9 "$pid" 2>/dev/null || true; fi
  [[ -f "$BRIDGEPID" ]] && { kill "$(cat "$BRIDGEPID")" 2>/dev/null || true; }
  rm -f "$PIDFILE" "$BRIDGEPID" "$QMP" "$CLIP"
  log "stopped (overlay kept; 'up' resumes it)"
}

destroy() {
  down
  rm -f "$WORK" "$EFIVARS" "$KNOWN_HOSTS" "$STATE/qemu.out" "$STATE/clipboard-bridge.log"
  if [[ "${1:-}" == --all ]]; then
    rm -f "$FACTORY" "$STATE/factory-info.txt" "$STATE"/debian-13-generic-arm64.qcow2 "$STATE/SHA512SUMS"
    log "destroyed: overlay, vars store, factory, base image (runtime kept in $RT)"
  else
    log "destroyed: overlay and vars store (factory kept; --all removes it too)"
  fi
}

rebuild() { down; rm -f "$WORK" "$EFIVARS" "$KNOWN_HOSTS"; "$REPO/guest/build.sh" --force; }

ssh_guest() { ssh "${SSH_OPTS[@]}" "$USER_NAME@localhost" "$@"; }

wait_ssh() { for i in {1..60}; do ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER_NAME@localhost" true 2>/dev/null && return 0; sleep 2; done; return 1; }

preflight() {
  up
  log "waiting for ssh"; wait_ssh || die "ssh did not answer; kdevm.sh console"
  log "graphics preflight (sddm stopped for the duration)"
  ssh_guest 'bash -s' <<'EOF'
set -u
echo "--- id: $(id)"
sudo systemctl stop sddm; sleep 2
echo "--- /dev/dri:"; ls -l /dev/dri 2>&1
echo "--- acls:"; getfacl /dev/dri/card0 /dev/dri/renderD128 2>/dev/null | grep -E '^(# file|user:)' || true
echo "--- eglinfo -B:"; eglinfo -B 2>&1 | grep -E -i 'platform|renderer|vendor|version|llvmpipe|virgl' | head -20
echo "--- kmscube 300 frames (watch the Mac window):"
if kmscube -c 300 >/tmp/kmscube.log 2>&1; then echo "kmscube OK as $USER"; tail -2 /tmp/kmscube.log
elif sudo kmscube -c 300 >/tmp/kmscube.log 2>&1; then echo "kmscube OK only under sudo (seat ACL, not the GPU stack)"; tail -2 /tmp/kmscube.log
else echo "kmscube FAILED"; tail -5 /tmp/kmscube.log; fi
sudo systemctl start sddm
echo "--- verdict:"
if [ ! -e /dev/dri/card0 ]; then echo "NO /dev/dri: kernel, device line, or QEMU"
elif eglinfo -B 2>/dev/null | grep -q -i llvmpipe && ! eglinfo -B 2>/dev/null | grep -q -i virgl; then echo "llvmpipe only: Mesa, virgl, or the renderer"
elif eglinfo -B 2>/dev/null | grep -q -i virgl; then echo "virgl present: GPU stack OK; anything wrong from here is KWin, KScreen, or the session"
else echo "inconclusive: read the eglinfo output above"; fi
EOF
}

status() {
  echo "-- runtime: $(readlink "$RT" 2>/dev/null | xargs basename 2>/dev/null || echo missing)  $( [[ -x "$QEMU" ]] && "$QEMU" --version | head -1 )"
  if [[ -f "$FACTORY" ]]; then
    echo "-- factory: $FACTORY, $(du -h "$FACTORY" | cut -f1), built $(stat -f %Sm -t %Y-%m-%d\ %H:%M "$FACTORY")"
  else echo "-- factory: none (kdevm.sh factory)"; fi
  if [[ -f "$WORK" ]]; then
    echo "-- overlay: $WORK, allocated $(du -h "$WORK" | cut -f1), virtual $("$QEMU_IMG" info "$WORK" 2>/dev/null | awk -F': ' '/virtual size/{print $2}')"
  else echo "-- overlay: none"; fi
  echo "-- config: $CPUS vCPU, ${MEM_MB} MB, scale $(scale_hint), share $SHARE"
  if running; then
    echo "-- qemu: pid $(qemu_pid), $(qmp query-status 2>/dev/null || echo 'QMP not answering')"
    [[ -f "$BRIDGEPID" ]] && kill -0 "$(cat "$BRIDGEPID")" 2>/dev/null && echo "-- clipboard bridge: supervisor pid $(cat "$BRIDGEPID"), helper $(pgrep -f 'bridge-native-clipboard' | head -1 || echo not-running)"
    if nc -z -G 2 localhost "$SSH_PORT" 2>/dev/null; then
      echo "-- ssh: localhost:$SSH_PORT answering"
      ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER_NAME@localhost" \
        'echo "-- guest: $(uname -r), session $(loginctl show-session $(loginctl list-sessions --no-legend | awk "\$3==\"'"$USER_NAME"'\"{print \$1; exit}") -p Type --value 2>/dev/null || echo unknown), uptime $(uptime -p)"' 2>/dev/null || echo "-- guest: ssh not accepting the key yet"
    else echo "-- ssh: localhost:$SSH_PORT not answering"; fi
  else echo "-- qemu: not running"; fi
}

case "${1:-}" in
  runtime)   "$REPO/runtime/build.sh" "${@:2}" ;;
  factory)   ensure_runtime; "$REPO/guest/build.sh" "${@:2}" ;;
  up|launch) up ;;
  preflight) preflight ;;
  down)      down ;;
  destroy)   destroy "${2:-}" ;;
  rebuild)   rebuild ;;
  status)    status ;;
  ssh)       ssh_guest "${@:2}" ;;
  console)   tail -n 50 -f "$SERIAL" ;;
  *) echo "usage: kdevm.sh {runtime|factory|up|launch|preflight|down|destroy [--all]|rebuild|status|ssh [cmd]|console}"; exit 1 ;;
esac
