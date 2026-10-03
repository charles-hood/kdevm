#!/bin/zsh
# kdevm: the Debian 13 + KDE Plasma desktop as a GPU-accelerated QEMU VM on
# this Mac, in a native window. Runtime: try-omarchy's patched QEMU (HVF,
# Cocoa + VirGL, SLIRP, SDL duplex audio, virtio-9p) and its Swift helper for
# the clipboard bridge. Guest: our own Debian factory (guest/build.sh).
#
#   kdevm.sh runtime     build/stage the QEMU runtime + helper
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
# Config: environment variables, optionally set in ~/.config/kdevm/env
# (sourced if present). KDEVM_CPUS (4) KDEVM_MEM_MB (8192) KDEVM_SCALE
# (auto|1|2) KDEVM_SHARE (~/kdevm-share) KDEVM_FULLSCREEN (off) KDEVM_WINDOW
# (auto|keep|WxH) KDEVM_USER (your login name) KDEVM_RUNTIME_ROOT
# (~/.local/share/kdevm/runtime) KDEVM_STATE (~/.cache/kdevm). Everything
# large lives outside the repo.
set -euo pipefail
umask 077   # overlay, vars store, sockets, logs: owner-only from creation

REPO="$(cd "$(dirname "$0")" && pwd)"
# ~/.config/kdevm/env holds defaults; a variable already set in the
# environment (even to the empty string) wins. Any NAME=value line is read
# (KDEVM_*, QEMU_IMG, ...); values may reference $HOME.
kdevm_load_env() {
  local f="$HOME/.config/kdevm/env" line k v; [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ '^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$' ]] || continue
    k="${match[2]}"; v="${match[3]}"
    [[ -n "${(P)k+set}" ]] && continue
    eval "export $k=$v"
  done < "$f"
}
kdevm_load_env
STATE="${KDEVM_STATE:-$HOME/.cache/kdevm}"
RT="${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current"
QEMU="$RT/bin/qemu-system-aarch64"
HELPER="$RT/bin/omarchy-vm-helper"
QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
FW_CODE="${KDEVM_FW_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
FW_VARS_TEMPLATE="${KDEVM_FW_VARS:-/opt/homebrew/share/qemu/edk2-arm-vars.fd}"
USER_NAME="${KDEVM_USER:-$(id -un)}"
SSH_PORT="${KDEVM_SSH_PORT:-2222}"
CPUS="${KDEVM_CPUS:-4}"
MEM_MB="${KDEVM_MEM_MB:-8192}"
SHARE="${KDEVM_SHARE:-$HOME/kdevm-share}"
FULLSCREEN="${KDEVM_FULLSCREEN:-off}"

FACTORY="$STATE/factory.qcow2"
WORK="$STATE/work.qcow2"
EFIVARS="$STATE/efivars.fd"
RUN="$STATE/run"                 # mode 0700: the helper refuses sockets in a shared dir
QMP="$RUN/qmp.sock"
CLIP="$RUN/clipboard.sock"
SERIAL="$STATE/serial.log"
PIDFILE="$STATE/qemu.pid"
BRIDGEPID="$STATE/clipboard-bridge.pid"
KNOWN_HOSTS="$STATE/known_hosts"
SSH_OPTS=(-p "$SSH_PORT" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=no
          -o LogLevel=ERROR -o ConnectTimeout=5)

die() { echo "kdevm: $*" >&2; exit 1; }
log() { echo "== $*"; }

# Pid files hold "pid start-time". A saved pid counts only if that pid is
# alive, started at the recorded time (so a reused number never matches),
# and shows the expected command line: for QEMU, our binary on our overlay;
# for the clipboard supervisor, the argv[0] it is launched with.
# ps pads lstart with spaces; awk collapses all whitespace so the saved and
# the live value compare equal.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1; print}'; }
read_pidfile() {
  local f=$1 line; [[ -f "$f" ]] || return 1
  line=$(head -1 "$f" | awk '{$1=$1; print}'); PF_PID="${line%% *}"; PF_START="${line#* }"
  [[ "$PF_PID" == "$line" ]] && PF_START=""
  [[ "$PF_PID" =~ ^[1-9][0-9]*$ ]]
}
pid_matches() { # pid start-time command-pattern (zsh glob)
  local pid=$1 start=$2 pat=$3 cmd
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
  [[ -n "$cmd" && "$cmd" == ${~pat} ]] || return 1
  [[ -z "$start" || "$(proc_start "$pid")" == "$start" ]]
}
qemu_pid() {
  local PF_PID PF_START
  if read_pidfile "$PIDFILE" && pid_matches "$PF_PID" "$PF_START" "*${QEMU}*file=${WORK}*"; then echo "$PF_PID"; else rm -f "$PIDFILE"; fi
}
running() { [[ -n "$(qemu_pid)" ]]; }
bridge_pid() {
  local PF_PID PF_START
  if read_pidfile "$BRIDGEPID" && pid_matches "$PF_PID" "$PF_START" "kdevm-bridge-supervisor *"; then echo "$PF_PID"; else rm -f "$BRIDGEPID"; fi
}

# One lock per state directory for every state-changing verb; guest/build.sh
# sees KDEVM_LOCKED=1 and does not take it again. mkdir is atomic. A lock
# whose recorded holder is dead is taken over EXCLUSIVELY: contenders race
# to rename it away, only one rename succeeds, and the loser's next mkdir
# finds the winner's fresh lock. Released by the script-scope EXIT trap
# (a trap set inside a function would fire when the function returns).
LOCK="$STATE/lock"
take_lock() {
  local attempt holder
  install -d -m 700 "$STATE"
  for attempt in 1 2 3 4 5; do
    if mkdir "$LOCK" 2>/dev/null; then
      echo $$ > "$LOCK/pid"; KDEVM_LOCK_HELD=1; export KDEVM_LOCKED=1; return 0
    fi
    holder=$(cat "$LOCK/pid" 2>/dev/null || echo 0)
    if [[ "$holder" =~ ^[1-9][0-9]*$ ]] && kill -0 "$holder" 2>/dev/null; then
      die "another kdevm command is running (pid $holder); wait for it"
    fi
    mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$"
    sleep 0.2
  done
  die "cannot take the lock $LOCK"
}
kdevm_exit() { [[ -n "${KDEVM_LOCK_HELD:-}" ]] && rm -rf "$LOCK"; return 0; }
trap kdevm_exit EXIT

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

# Main display pixel size "W H" (1920 1080 if unreadable). The initial
# virtio-gpu mode is set to it so the first window opens near full size
# (Cocoa sizes the window in points = pixels / scale, then zoom-to-fit keeps
# it on screen); without this the first window came up at 492x277 points.
display_pixels() {
  system_profiler -json SPDisplaysDataType 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for g in d["SPDisplaysDataType"]:
        for disp in g.get("spdisplays_ndrvs", []):
            if disp.get("spdisplays_main") == "spdisplays_yes":
                w, h = disp["_spdisplays_pixels"].replace(" ", "").split("x"); print(w, h); raise SystemExit
except Exception:
    pass
print("1920 1080")'
}

# Scale hint for the guest. The Cocoa dynamic-display patch publishes the
# window's BACKING-pixel size, so on a 2x display (Retina, or a 4K panel run
# at 1920x1080 points like the M32UC) the guest needs scale 2 to look normal.
# auto = pixels / points of the main display, rounded; KDEVM_SCALE overrides.
scale_hint() {
  case "${KDEVM_SCALE:-auto}" in
    auto)
      system_profiler -json SPDisplaysDataType 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for g in d["SPDisplaysDataType"]:
        for disp in g.get("spdisplays_ndrvs", []):
            if disp.get("spdisplays_main") == "spdisplays_yes":
                px = int(disp["_spdisplays_pixels"].split("x")[0])
                pt = int(disp["_spdisplays_resolution"].split("x")[0])
                print(2 if px >= pt * 1.5 else 1); raise SystemExit
except Exception:
    pass
print(1)' ;;
    *) echo "$KDEVM_SCALE" ;;
  esac
}

ensure_runtime() { [[ -x "$QEMU" && -x "$HELPER" ]] || { log "runtime missing; building"; "$REPO/runtime/build.sh"; }; }
ensure_factory() { [[ -f "$FACTORY" ]] || { log "factory missing; building (about 10 min)"; "$REPO/guest/build.sh"; }; }

up() {
  ensure_runtime; ensure_factory
  if running; then log "already running (pid $(qemu_pid))"; return 0; fi
  install -d -m 700 "$STATE" "$RUN"; chmod 700 "$STATE"; mkdir -p "$SHARE"
  [[ -f "$WORK" ]] || { log "new overlay on the factory"; "$QEMU_IMG" create -q -f qcow2 -b "$FACTORY" -F qcow2 "$WORK"; }
  # Private UEFI variable store: a copy of the template, never the template.
  [[ -f "$EFIVARS" ]] || cp "$FW_VARS_TEMPLATE" "$EFIVARS"
  chmod 600 "$WORK" "$EFIVARS" "$FACTORY" 2>/dev/null || true
  # Defence in depth: a QEMU on this overlay that the pid file does not know
  # about (pid file lost, identity check failed) must not be started beside.
  local stray; stray=$(pgrep -f -- "file=$WORK" | head -1 || true)
  [[ -n "$stray" ]] && die "a QEMU already runs on $WORK (pid $stray) but is not tracked; stop it (kdevm.sh ssh 'sudo poweroff', or kill $stray) before up"
  rm -f "$QMP" "$CLIP"
  # The helper's bridges accept only a socket owned by this uid with no
  # group/other bits (NativeBridgeSocket.swift); the script-wide umask 077
  # makes QEMU create them that way.
  local out_hz in_hz scale xres yres
  read -r xres yres < <(display_pixels)
  out_hz=$("$HELPER" --host-audio-frequency output 2>/dev/null || echo 48000)
  in_hz=$("$HELPER" --host-audio-frequency input 2>/dev/null || echo 48000)
  scale=$(scale_hint)
  log "starting: $CPUS vCPU, ${MEM_MB} MB, initial mode ${xres}x${yres}, scale hint $scale, audio ${out_hz}/${in_hz} Hz, share $SHARE"
  # gic-version=3 is mandatory on this QEMU under HVF. romfile= on every PCI
  # device: the runtime ships no option ROMs and UEFI boots from disk anyway.
  "$QEMU" -name kdevm \
    -machine virt,accel=hvf,gic-version=3 -cpu host,pmu=off \
    -smp "$CPUS,sockets=1,cores=$CPUS,threads=1" -m "${MEM_MB}M" -nodefaults \
    -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
    -drive if=pflash,format=raw,file="$EFIVARS" \
    -drive if=none,id=root,file="$WORK",format=qcow2,cache=writeback \
    -device virtio-blk-pci,drive=root,romfile= \
    -device "virtio-gpu-gl-pci,max_outputs=1,xres=$xres,yres=$yres,romfile=" \
    -display "cocoa,gl=on,show-cursor=on,zoom-to-fit=on,full-screen=$FULLSCREEN,full-grab=on,immersive=off,swap-opt-cmd=off" \
    -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= -device virtio-pinch-pci,romfile= \
    -audiodev "sdl,id=snd,timer-period=1000,out.buffer-count=8,out.frequency=$out_hz,in.frequency=$in_hz" \
    -device intel-hda -device hda-micro,audiodev=snd \
    -netdev "user,id=net,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net,romfile= \
    -object rng-random,id=rng,filename=/dev/urandom -device virtio-rng-pci,rng=rng \
    -device virtio-balloon-pci,free-page-reporting=on \
    -fsdev "local,id=share,path=$SHARE,security_model=none,guest_owner_uid=1000,guest_owner_gid=1000" \
    -device virtio-9p-pci,fsdev=share,mount_tag=mac,romfile= \
    -device virtio-serial-pci,id=vser,romfile= \
    -chardev "socket,id=clip,path=$CLIP,server=on,wait=off" \
    -device virtserialport,bus=vser.0,nr=2,chardev=clip,name=dev.tryomarchy.clipboard \
    -fw_cfg "name=opt/kdevm/scale,string=$scale" \
    -qmp "unix:$QMP,server=on,wait=off" -serial "file:$SERIAL" -monitor none \
    >"$STATE/qemu.out" 2>&1 &
  local pid=$!
  echo "$pid $(proc_start $pid)" > "$PIDFILE"
  for i in {1..100}; do [[ -S "$QMP" && -S "$CLIP" ]] && break; kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  # The sockets appear before the disks are opened, so their existence proves
  # nothing: the process must still be alive and QMP must answer.
  local alive=0
  for i in {1..50}; do
    kill -0 $pid 2>/dev/null || break
    qmp query-status >/dev/null 2>&1 && { alive=1; break; }
    sleep 0.2
  done
  [[ $alive -eq 1 ]] || { rm -f "$PIDFILE"; cat "$STATE/qemu.out" >&2; die "QEMU exited at start (see above)"; }
  # Clipboard bridge: their helper, supervised while QEMU lives (as their
  # launcher does). The supervisor is its own zsh process with a distinctive
  # argv[0] (ARGV0) so bridge_pid() can recognise it, with stdio detached so
  # no inherited pipe stays open until QEMU exits.
  ARGV0="kdevm-bridge-supervisor $pid" zsh -c '
    helper=$1; qpid=$2; sock=$3; logf=$4
    while kill -0 "$qpid" 2>/dev/null; do
      "$helper" --bridge-native-clipboard "$qpid" "$sock" >>"$logf" 2>&1 || true
      kill -0 "$qpid" 2>/dev/null && sleep 1
    done' kdevm-bridge-supervisor "$HELPER" "$pid" "$CLIP" "$STATE/clipboard-bridge.log" </dev/null >/dev/null 2>&1 &
  local spid=$!
  echo "$spid $(proc_start $spid)" > "$BRIDGEPID"
  # Window size: KScreen restores the guest's last mode and the Cocoa window
  # follows the guest, so the first window can come up small (492x277 points
  # seen). Once the window exists, size it to the display minus margins; the
  # guest follows through the EDID. KDEVM_WINDOW=WxH overrides; "keep" skips.
  # Needs Accessibility for the calling terminal; failure is silent.
  ( trap - EXIT; local w h pw ph; read -r pw ph < <(display_pixels); pw=$((pw / $(scale_hint))); ph=$((ph / $(scale_hint)))
    case "${KDEVM_WINDOW:-auto}" in
      keep) exit 0 ;;
      auto) w=$((pw - 80)); h=$((ph - 140)) ;;
      *) w=${KDEVM_WINDOW%x*}; h=${KDEVM_WINDOW#*x} ;;
    esac
    for i in {1..40}; do
      osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set position of window 1 to {40, 50}" \
                -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set size of window 1 to {$w, $h}" >/dev/null 2>&1 && exit 0
      sleep 0.5
    done ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  log "up: pid $pid, window open; ssh with: kdevm.sh ssh"
}

down() {
  if ! running; then
    # No QEMU: a verified supervisor of ours (if any lingers) is stopped too.
    local lp; lp=$(bridge_pid); [[ -n "$lp" ]] && { kill "$lp" 2>/dev/null || true; }
    rm -f "$BRIDGEPID" "$PIDFILE"; log "not running"; return 0
  fi
  local pid; pid=$(qemu_pid)
  # Plasma's power manager owns the ACPI power button and does not shut down
  # on it (seen 2026-10-02: QMP system_powerdown, 30 s, nothing), so ask the
  # guest's systemd over ssh first; QMP powerdown is the fallback for a guest
  # without ssh; a kill is the last resort.
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER_NAME@localhost" 'sudo systemctl poweroff' >/dev/null 2>&1; then
    log "power-off via ssh (systemctl poweroff)"
  else
    log "ssh not answering; power-off via QMP"
    qmp system_powerdown >/dev/null 2>&1 || true
  fi
  for i in {1..45}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then log "guest did not power off in 45 s; terminating"; kill "$pid"; sleep 2; kill -9 "$pid" 2>/dev/null || true; fi
  local bpid; bpid=$(bridge_pid); [[ -n "$bpid" ]] && { kill "$bpid" 2>/dev/null || true; }
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
    [[ -n "$(bridge_pid)" ]] && echo "-- clipboard bridge: supervisor pid $(bridge_pid), helper $(pgrep -f 'bridge-native-clipboard' | head -1 || echo not-running)"
    if nc -z -G 2 localhost "$SSH_PORT" 2>/dev/null; then
      echo "-- ssh: localhost:$SSH_PORT answering"
      ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER_NAME@localhost" \
        'echo "-- guest: $(uname -r), seat session $(loginctl show-session $(loginctl list-sessions --no-legend | awk "\$4==\"seat0\"{print \$1; exit}") -p Type --value 2>/dev/null || echo none), uptime $(uptime -p)"' 2>/dev/null || echo "-- guest: ssh not accepting the key yet"
    else echo "-- ssh: localhost:$SSH_PORT not answering"; fi
  else echo "-- qemu: not running"; fi
}

case "${1:-}" in
  runtime)   "$REPO/runtime/build.sh" "${@:2}" ;;
  factory)   take_lock; ensure_runtime; "$REPO/guest/build.sh" "${@:2}" ;;
  up|launch) take_lock; up ;;
  preflight) take_lock; preflight ;;
  down)      take_lock; down ;;
  destroy)   take_lock; destroy "${2:-}" ;;
  rebuild)   take_lock; rebuild ;;
  status)    status ;;
  ssh)       ssh_guest "${@:2}" ;;
  console)   tail -n 50 -f "$SERIAL" ;;
  _lockprobe) take_lock; echo "held"; sleep "${2:-3}" ;;   # for tests/checks.sh: hold the lock for N seconds
  *) echo "usage: kdevm.sh {runtime|factory|up|launch|preflight|down|destroy [--all]|rebuild|status|ssh [cmd]|console}"; exit 1 ;;
esac
