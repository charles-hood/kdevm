#!/bin/zsh
# kdevm: the Debian 13 + KDE Plasma desktop as a GPU-accelerated QEMU VM on
# this Mac, in a native window. Runtime: try-omarchy's patched QEMU (HVF,
# Cocoa + VirGL, SLIRP, SDL duplex audio, virtio-9p) and its Swift helper for
# the clipboard, time zone and battery bridges. Guest: our own Debian factory
# (guest/build.sh).
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
# (auto|keep|WxH) KDEVM_ICON (assets/kdevm-icon.png) KDEVM_TIMEZONE
# (mirror|off) KDEVM_USER (your login name) KDEVM_RUNTIME_ROOT
# (~/.local/share/kdevm/runtime) KDEVM_STATE (~/.cache/kdevm). Everything
# large lives outside the repo.
set -euo pipefail
umask 077   # overlay, vars store, sockets, logs: owner-only from creation

REPO="$(cd "$(dirname "$0")" && pwd)"
KDEVM_TOOL=kdevm
source "$REPO/lib/kdevm-common.zsh"
kdevm_load_env
STATE="${KDEVM_STATE:-$HOME/.cache/kdevm}"
RT="${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current"
QEMU="$RT/bin/kdevm"   # QEMU, under the name macOS shows for it (runtime/build.sh)
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
TIMEZONE="${KDEVM_TIMEZONE:-mirror}"   # mirror: the guest follows the Mac's time zone; off: no port, no bridge

FACTORY="$STATE/factory.qcow2"
WORK="$STATE/work.qcow2"
EFIVARS="$STATE/efivars.fd"
RUN="$STATE/run"                 # mode 0700: the helper refuses sockets in a shared dir
QMP="$RUN/qmp.sock"
CLIP="$RUN/clipboard.sock"
TZSOCK="$RUN/timezone.sock"
BATSOCK="$RUN/battery.sock"
SOCKETS=("$QMP" "$CLIP" "$TZSOCK" "$BATSOCK")
# Host bridges: name -> the socket QEMU serves for it. One helper process per
# bridge, started by up; each has its own record, bridge-<name>.pid, holding
# "pid start-time" and checked against the helper's command line, exactly as
# QEMU's record is. No process supervises them.
typeset -A BRIDGE_SOCK
BRIDGE_SOCK=(clipboard "$CLIP" battery "$BATSOCK" timezone "$TZSOCK")
BRIDGE_NAMES=(clipboard battery timezone)
SERIAL="$STATE/serial.log"
PIDFILE="$STATE/qemu.pid"
KNOWN_HOSTS="$STATE/known_hosts"
SSH_OPTS=(-p "$SSH_PORT" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=no
          -o LogLevel=ERROR -o ConnectTimeout=5)

source "$REPO/guest/factory.zsh"
trap kdevm_factory_cleanup EXIT   # script scope; a no-op unless a build started

QEMU_PATTERN="*${QEMU}*file=${WORK}*"
# qemu_state -> running | unknown | absent (see pid_state in the library).
# An absent record is discarded; an unknown one is KEPT so a later command
# cannot mistake "could not inspect" for "gone".
qemu_state() { local PF_PID PF_START; read_pidfile "$PIDFILE" || { echo absent; return 0; }; pid_state "$PF_PID" "$PF_START" "$QEMU_PATTERN"; }
qemu_pid() {
  local PF_PID PF_START st; read_pidfile "$PIDFILE" || return 0
  st=$(pid_state "$PF_PID" "$PF_START" "$QEMU_PATTERN")
  case $st in running) echo "$PF_PID" ;; absent) rm -f "$PIDFILE" ;; esac
}
running() { [[ "$(qemu_state)" == running ]]; }
bridge_record() { echo "$STATE/bridge-$1.pid"; } # name
# The helper's command line for one bridge; (b) quotes the literal parts so a
# path cannot act as a pattern. The QEMU pid in the middle is not pinned: the
# record's own pid and start time identify the process.
bridge_pattern() { echo "*${(b)HELPER} --bridge-native-$1 * ${(b)BRIDGE_SOCK[$1]}"; } # name
bridge_state() { # name -> running | unknown | absent
  local PF_PID PF_START; read_pidfile "$(bridge_record $1)" || { echo absent; return 0; }
  pid_state "$PF_PID" "$PF_START" "$(bridge_pattern $1)"
}
# Stop one bridge helper with the same tri-state rules as QEMU:
# running -> signal, remove the record only after the exit is confirmed;
# absent  -> remove the stale record;
# unknown -> signal nothing, keep the record, say so. Returns 1 when the
# record had to be preserved (unknown, or no confirmed exit).
stop_bridge() { # name
  local PF_PID PF_START st i rec; rec=$(bridge_record $1)
  read_pidfile "$rec" || return 0
  st=$(pid_state "$PF_PID" "$PF_START" "$(bridge_pattern $1)")
  case $st in
    running)
      kill "$PF_PID" 2>/dev/null || true
      for i in {1..25}; do kill -0 "$PF_PID" 2>/dev/null || break; sleep 0.2; done
      if kill -0 "$PF_PID" 2>/dev/null; then
        log "$1 bridge helper pid $PF_PID did not exit after SIGTERM; tracking preserved"; return 1
      fi
      rm -f "$rec" ;;
    absent)  rm -f "$rec" ;;
    unknown) log "$1 bridge helper pid $PF_PID could not be verified (process inspection failed); not signalled, tracking preserved"; return 1 ;;
  esac
  return 0
}
stop_bridges() { local rc=0 n; for n in $BRIDGE_NAMES; do stop_bridge $n || rc=1; done; return $rc; }
# A QEMU that has this state's overlay open but that the pid record does not
# vouch for (record lost, written by an older kdevm, identity check failed)
# must not be started beside, and its disks must not be removed from under
# it. Fixed-string match on the process table; the needle travels in the
# environment so the matcher cannot find itself.
refuse_if_stray() { # verb
  local stray
  stray=$(ps -axo pid=,command= | NEEDLE="file=$WORK" awk 'index($0, ENVIRON["NEEDLE"]) { print $1; exit }')
  [[ -z "$stray" ]] || die "a QEMU has $WORK open (pid $stray) but is not tracked; refusing to $1. Stop it first (kdevm.sh ssh 'sudo poweroff', or kill $stray)"
}
refuse_if_unknown() { # verb
  local PF_PID PF_START
  if [[ "$(qemu_state)" == unknown ]]; then
    read_pidfile "$PIDFILE"
    die "pid $PF_PID is alive but cannot be inspected; refusing to $1 (check: ps -p $PF_PID; if it is not kdevm's QEMU, remove $PIDFILE)"
  fi
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

# Dock icon. The runtime's Cocoa product-identity patch loads TryOmarchy.icns
# from the runtime root (three directories above the binary; the file name is
# compiled in), and without that file the Dock shows the generic "exec" icon.
# Built on every up (a quarter of a second) from a square PNG: KDEVM_ICON,
# else the one in the repo. sips can exit 0 without writing anything, so each
# output is checked; iconutil only writes to a name ending in .icns.
# Cosmetic: the caller turns a failure into a warning.
install_icon() {
  local src="${KDEVM_ICON:-$REPO/assets/kdevm-icon.png}" dest="${RT:h}/TryOmarchy.icns" new="${RT:h}/TryOmarchy.new.$$.icns" set="$STATE/icon.iconset" s f
  [[ -f "$src" ]] || return 1
  {
    rm -rf "$set"; mkdir "$set" || return 1
    for s in 16 32 128 256 512; do
      f="$set/icon_${s}x${s}.png"
      sips -z $s $s "$src" --out "$f" >/dev/null 2>&1; [[ -s "$f" ]] || return 1
      f="$set/icon_${s}x${s}@2x.png"
      sips -z $((s * 2)) $((s * 2)) "$src" --out "$f" >/dev/null 2>&1; [[ -s "$f" ]] || return 1
    done
    iconutil -c icns -o "$new" "$set" 2>/dev/null || return 1
    mv -f "$new" "$dest" || return 1
  } always { rm -rf "$set" "$new" }
}

ensure_runtime() { [[ -x "$QEMU" && -x "$HELPER" ]] || { log "runtime missing; building"; "$REPO/runtime/build.sh"; }; }
# The factory is built by THIS process (which holds the lock), never delegated.
ensure_factory() { [[ -f "$FACTORY" ]] || { log "factory missing; building (about 2 min)"; kdevm_factory_build; }; }

up() {
  # Configuration is checked before anything is built or launched.
  [[ "$TIMEZONE" == (mirror|off) ]] || die "KDEVM_TIMEZONE must be mirror or off, not '$TIMEZONE'"
  ensure_runtime; ensure_factory
  refuse_if_unknown "start"
  if running; then log "already running (pid $(qemu_pid))"; return 0; fi
  install -d -m 700 "$STATE" "$RUN"; chmod 700 "$STATE"; mkdir -p "$SHARE"
  [[ -f "$WORK" ]] || { log "new overlay on the factory"; "$QEMU_IMG" create -q -f qcow2 -b "$FACTORY" -F qcow2 "$WORK"; }
  # Private UEFI variable store: a copy of the template, never the template.
  [[ -f "$EFIVARS" ]] || cp "$FW_VARS_TEMPLATE" "$EFIVARS"
  chmod 600 "$WORK" "$EFIVARS" "$FACTORY" 2>/dev/null || true
  refuse_if_stray "start another"
  # A helper left from an earlier run (the guest powered itself off, so down
  # never ran) is stopped and its record dropped before new ones are written.
  stop_bridges || die "a bridge helper from an earlier run is still tracked and could not be stopped (kdevm.sh status); refusing to start"
  rm -f "${SOCKETS[@]}"
  install_icon || log "warning: could not build the Dock icon from ${KDEVM_ICON:-$REPO/assets/kdevm-icon.png}; the Dock icon is unchanged"
  # The helper's bridges accept only a socket owned by this uid with no
  # group/other bits (NativeBridgeSocket.swift); the script-wide umask 077
  # makes QEMU create them that way.
  local out_hz in_hz scale xres yres
  # Host bridges to start once QEMU is up (names; see BRIDGE_SOCK).
  # Time zone: a second virtio port the helper writes the Mac's zone to every
  # five seconds; the guest's kdevm-timezone service (started by udev when
  # the port exists) applies it. Off: no port, so nothing runs on either side.
  # Battery: a third port carrying the Mac's battery state; the guest agent
  # feeds it to a kernel module that presents BAT0/ADP0 (a Mac without a
  # battery shows as mains only).
  local -a bridges tzdev
  bridges=(clipboard battery)
  if [[ "$TIMEZONE" == mirror ]]; then
    bridges+=(timezone)
    tzdev=(-chardev "socket,id=tz,path=$TZSOCK,server=on,wait=off"
           -device virtserialport,bus=vser.0,nr=8,chardev=tz,name=dev.tryomarchy.timezone)
  fi
  read -r xres yres < <(display_pixels)
  out_hz=$("$HELPER" --host-audio-frequency output 2>/dev/null || echo 48000)
  in_hz=$("$HELPER" --host-audio-frequency input 2>/dev/null || echo 48000)
  scale=$(scale_hint)
  log "starting: $CPUS vCPU, ${MEM_MB} MB, initial mode ${xres}x${yres}, scale hint $scale, audio ${out_hz}/${in_hz} Hz, time zone $TIMEZONE, share $SHARE"
  # gic-version=3 is mandatory on this QEMU under HVF. romfile= on every PCI
  # device: the runtime ships no option ROMs and UEFI boots from disk anyway.
  # show-cursor=off: Plasma draws the guest cursor into the scanout; with
  # show-cursor=on the Mac cursor stayed visible on top of it and the two
  # moved together as a double cursor (seen 2026-10-03). The Cocoa frontend
  # hides the host cursor while the pointer is over the guest view.
  "$QEMU" -name kdevm \
    -machine virt,accel=hvf,gic-version=3 -cpu host,pmu=off \
    -smp "$CPUS,sockets=1,cores=$CPUS,threads=1" -m "${MEM_MB}M" -nodefaults \
    -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
    -drive if=pflash,format=raw,file="$EFIVARS" \
    -drive if=none,id=root,file="$WORK",format=qcow2,cache=writeback \
    -device virtio-blk-pci,drive=root,romfile= \
    -device "virtio-gpu-gl-pci,max_outputs=1,xres=$xres,yres=$yres,romfile=" \
    -display "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-screen=$FULLSCREEN,full-grab=on,immersive=off,swap-opt-cmd=off" \
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
    "${tzdev[@]}" \
    -chardev "socket,id=bat,path=$BATSOCK,server=on,wait=off" \
    -device virtserialport,bus=vser.0,nr=7,chardev=bat,name=dev.tryomarchy.battery \
    -fw_cfg "name=opt/kdevm/scale,string=$scale" \
    -qmp "unix:$QMP,server=on,wait=off" -serial "file:$SERIAL" -monitor none \
    >"$STATE/qemu.out" 2>&1 {KDEVM_LOCK_FD}<&- &
  local pid=$! start
  # The child is ours from this moment: any failure to record its identity
  # terminates it (TERM, wait, KILL) before the command exits.
  start=$(proc_start $pid) || start=""
  if [[ -z "$start" ]]; then
    kill $pid 2>/dev/null || true
    for i in {1..25}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
    kill -0 $pid 2>/dev/null && { kill -9 $pid 2>/dev/null || true; sleep 0.5; }
    rm -f "${SOCKETS[@]}"
    die "could not record QEMU's start time (process inspection failed); the launched QEMU (pid $pid) was terminated"
  fi
  echo "$pid $start" > "$PIDFILE"
  for i in {1..100}; do [[ -S "$QMP" && -S "$CLIP" ]] && break; kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  # The sockets appear before the disks are opened, so their existence proves
  # nothing: QEMU must report "running" over QMP (qmp() fails on EOF or an
  # error reply) and still be alive afterwards. On failure, a child that is
  # still alive is OUR child and is terminated before the identity is dropped.
  local ready=0 st
  for i in {1..50}; do
    kill -0 $pid 2>/dev/null || break
    if st=$(qmp query-status 2>/dev/null) && [[ "$st" == *'"running": true'* ]]; then ready=1; break; fi
    sleep 0.2
  done
  kill -0 $pid 2>/dev/null || ready=0
  if [[ $ready -ne 1 ]]; then
    if kill -0 $pid 2>/dev/null; then
      log "QEMU did not become ready; terminating pid $pid"
      kill $pid 2>/dev/null || true
      for i in {1..25}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
      kill -0 $pid 2>/dev/null && { kill -9 $pid 2>/dev/null || true; sleep 0.5; }
    fi
    rm -f "$PIDFILE" "${SOCKETS[@]}"
    cat "$STATE/qemu.out" >&2
    die "QEMU failed to start (see above)"
  fi
  # Host bridges: their helper, one process per bridge, started here and
  # tracked like QEMU (pid and start time, checked against its command line).
  # Nothing supervises them: a helper that exits stays down until the next
  # up, and status says so. A helper ends by itself when QEMU closes its
  # socket; down stops any that has not. stdio is detached so no inherited
  # pipe stays open until QEMU exits.
  local name hp hstart
  for name in $bridges; do
    "$HELPER" --bridge-native-$name "$pid" "${BRIDGE_SOCK[$name]}" </dev/null >>"$STATE/bridges.log" 2>&1 {KDEVM_LOCK_FD}<&- &
    hp=$!; hstart=$(proc_start $hp) || hstart=""
    if [[ -n "$hstart" ]]; then
      echo "$hp $hstart" > "$(bridge_record $name)"
    elif kill -0 $hp 2>/dev/null; then
      # Our own child, this instant: stopping it by pid is safe. An
      # untrackable helper is not left behind.
      kill $hp 2>/dev/null || true
      log "warning: could not record the $name bridge helper's start time; it was stopped (no $name bridge this session)"
    else
      log "warning: the $name bridge helper exited at once (see $STATE/bridges.log); no $name bridge this session"
    fi
  done
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
  refuse_if_unknown "stop"
  if ! running; then
    # "Not running" is only true if nothing has the overlay open. destroy and
    # rebuild come through here before they remove anything.
    refuse_if_stray "treat the VM as stopped"
    # No QEMU: a verified helper of ours (if any lingers) is stopped too;
    # an unverifiable one keeps its record and down reports it (exit 2).
    local brc=0; stop_bridges || brc=$?
    rm -f "$PIDFILE"; log "not running"
    [[ $brc -eq 0 ]] || return 2
    return 0
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
  if kill -0 "$pid" 2>/dev/null; then log "guest did not power off in 45 s; terminating"; kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true; fi
  local brc=0; stop_bridges || brc=$?
  rm -f "$PIDFILE" "${SOCKETS[@]}"
  log "stopped (overlay kept; 'up' resumes it)"
  [[ $brc -eq 0 ]] || return 2
}

destroy() {
  down
  rm -f "$WORK" "$EFIVARS" "$KNOWN_HOSTS" "$STATE/qemu.out" "$STATE/bridges.log"
  if [[ "${1:-}" == --all ]]; then
    rm -f "$FACTORY" "$STATE/factory-info.txt" "$STATE"/debian-13-generic-arm64.qcow2 "$STATE/SHA512SUMS"
    log "destroyed: overlay, vars store, factory, base image (runtime kept in $RT)"
  else
    log "destroyed: overlay and vars store (factory kept; --all removes it too)"
  fi
}

rebuild() { down; rm -f "$WORK" "$EFIVARS" "$KNOWN_HOSTS"; ensure_runtime; kdevm_factory_build --force; }

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
  local qs; qs=$(qemu_state)
  if [[ "$qs" == unknown ]]; then
    echo "-- qemu: UNKNOWN: pid $(head -1 "$PIDFILE" | cut -d' ' -f1) is alive but could not be inspected; lifecycle verbs will refuse until this is resolved"
  elif running; then
    echo "-- qemu: pid $(qemu_pid), $(qmp query-status 2>/dev/null || echo 'QMP not answering')"
    if nc -z -G 2 localhost "$SSH_PORT" 2>/dev/null; then
      echo "-- ssh: localhost:$SSH_PORT answering"
      ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER_NAME@localhost" \
        'echo "-- guest: $(uname -r), seat session $(loginctl show-session $(loginctl list-sessions --no-legend | awk "\$4==\"seat0\"{print \$1; exit}") -p Type --value 2>/dev/null || echo none), uptime $(uptime -p)"' 2>/dev/null || echo "-- guest: ssh not accepting the key yet"
    else echo "-- ssh: localhost:$SSH_PORT not answering"; fi
  else echo "-- qemu: not running"; fi
  # Each bridge helper is reported independently of the QEMU state: running;
  # UNKNOWN (record preserved, nothing signalled); or, with QEMU up, absent
  # (it exited and nothing restarts it) or never started (no socket: off).
  # status changes nothing: a stale record is dropped by the next up or down.
  local n PF_PID PF_START
  for n in $BRIDGE_NAMES; do
    case "$(bridge_state $n)" in
      running) read_pidfile "$(bridge_record $n)"; echo "-- bridge $n: helper pid $PF_PID" ;;
      unknown) read_pidfile "$(bridge_record $n)"; echo "-- bridge $n: UNKNOWN: pid $PF_PID could not be inspected; tracking preserved, nothing signalled" ;;
      absent)  [[ "$qs" == running ]] || continue
               if [[ -S "${BRIDGE_SOCK[$n]}" ]]; then echo "-- bridge $n: NOT RUNNING (its helper exited; down and up restore it; see $STATE/bridges.log)"
               else echo "-- bridge $n: off"; fi ;;
    esac
  done
}

case "${1:-}" in
  runtime)   "$REPO/runtime/build.sh" "${@:2}" ;;
  factory)   take_lock; ensure_runtime; kdevm_factory_build "${2:-}" ;;
  up|launch) take_lock; up ;;
  preflight) take_lock; preflight ;;
  down)      take_lock; down ;;
  destroy)   take_lock; destroy "${2:-}" ;;
  rebuild)   take_lock; rebuild ;;
  status)    status ;;
  ssh)       ssh_guest "${@:2}" ;;
  console)   tail -n 50 -f "$SERIAL" ;;
  # for tests/checks.sh: hold the lock for N seconds; _lockprobe_spawn also
  # leaves a detached child (inherits fds) behind and exits at once
  _lockprobe) take_lock; echo "held"; sleep "${2:-3}" ;;
  _lockprobe_spawn) take_lock; sleep 30 </dev/null >/dev/null 2>&1 & disown; echo "held $!" ;;
  *) echo "usage: kdevm.sh {runtime|factory|up|launch|preflight|down|destroy [--all]|rebuild|status|ssh [cmd]|console}"; exit 1 ;;
esac
