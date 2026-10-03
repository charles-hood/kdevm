# kdevm shared library. Sourced (zsh) by kdevm.sh, guest/build.sh,
# runtime/build.sh and tests/checks.sh. Callers set KDEVM_TOOL (message
# prefix) before sourcing, STATE before using the lock, QMP before using qmp.

die() { echo "${KDEVM_TOOL:-kdevm}: $*" >&2; exit 1; }
log() { echo "== $*"; }

# ---- configuration ---------------------------------------------------------
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

# ---- process identity ------------------------------------------------------
# Pid files hold "pid start-time". ps pads lstart with spaces; awk collapses
# whitespace so saved and live values compare equal.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1; print}'; }
proc_cmd() { ps -o command= -p "$1" 2>/dev/null; }
# read_pidfile FILE: sets PF_PID and PF_START (PF_START may be empty for a
# malformed record); returns 1 if the file is missing or the pid is not a number.
read_pidfile() {
  local f=$1 line; [[ -f "$f" ]] || return 1
  line=$(head -1 "$f" 2>/dev/null | awk '{$1=$1; print}')
  PF_PID="${line%% *}"; PF_START="${line#* }"
  [[ "$PF_PID" == "$line" ]] && PF_START=""
  [[ "$PF_PID" =~ ^[1-9][0-9]*$ ]]
}
# pid_state PID START PATTERN -> running | unknown | absent
#   running: alive, command matches the zsh glob PATTERN, started at START
#   absent:  no such process, or a successfully inspected process that is a
#            different identity (other command, or same command but another
#            start time), or a record with no start time (an unverifiable
#            record is never treated as ours)
#   unknown: the process exists but could not be inspected (permission, ps
#            failure, empty output from either lookup); callers must neither
#            signal it nor assume it is gone
pid_state() {
  local pid=$1 start=$2 pat=$3 cmd err live
  [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$start" ]] || { echo absent; return 0; }
  if ! err=$(kill -0 "$pid" 2>&1); then
    [[ "$err" == *ermitted* ]] && echo unknown || echo absent; return 0
  fi
  cmd=$(proc_cmd "$pid") || { echo unknown; return 0; }
  [[ -n "$cmd" ]] || { echo unknown; return 0; }
  [[ "$cmd" == ${~pat} ]] || { echo absent; return 0; }
  live=$(proc_start "$pid") || { echo unknown; return 0; }
  [[ -n "$live" ]] || { echo unknown; return 0; }
  [[ "$live" == "$start" ]] && echo running || echo absent
}

# ---- lock ------------------------------------------------------------------
# One lock directory per state directory, taken by every state-changing verb
# and by the factory build (which skips it when KDEVM_LOCKED=1 says the
# caller already holds it). Acquisition is one atomic rename of a directory
# that already contains the owner pid, so the lock never exists without its
# owner recorded. FAIL-CLOSED: if the lock exists, the command exits, whether
# the owner is alive (wait for it) or gone (a crash left it: run
# `kdevm.sh unlock`, which removes it only after verifying the owner is not
# running). There is no automatic takeover. An EMPTY directory at the lock
# path has no owner and is not a lock: rename(2) replaces it atomically, and
# only one contender's rename can win.
lock_owner() { cat "$LOCK/pid" 2>/dev/null || true; }
holder_alive() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null; }
take_lock() {
  local holder tmp
  install -d -m 700 "$STATE"
  LOCK="${LOCK:-$STATE/lock}"
  tmp="$LOCK.new.$$"; rm -rf "$tmp"
  mkdir -m 700 "$tmp" && echo $$ > "$tmp/pid"
  if python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$tmp" "$LOCK" 2>/dev/null; then
    KDEVM_LOCK_HELD=1; export KDEVM_LOCKED=1; return 0
  fi
  rm -rf "$tmp"
  holder=$(lock_owner)
  if holder_alive "$holder"; then
    die "another kdevm command is running (pid $holder); wait for it"
  fi
  die "stale lock at $LOCK (owner pid '${holder:-?}' is not running); check nothing of kdevm's is still running, then: kdevm.sh unlock"
}
# Only the process that took the lock releases it, and only if it still owns it.
release_lock() { [[ -n "${KDEVM_LOCK_HELD:-}" && "$(lock_owner)" == "$$" ]] && rm -rf "$LOCK"; return 0; }
# Explicit stale-lock recovery: refuses while the recorded owner is alive.
unlock() {
  LOCK="${LOCK:-$STATE/lock}"
  [[ -d "$LOCK" ]] || { log "no lock at $LOCK"; return 0; }
  local holder; holder=$(lock_owner)
  holder_alive "$holder" && die "lock owner pid $holder is still running; not removing $LOCK"
  rm -rf "$LOCK"; log "removed stale lock $LOCK (owner pid '${holder:-?}' not running)"
}

# ---- QMP -------------------------------------------------------------------
# qmp COMMAND: one command over the unix socket $QMP. Prints the "return"
# value and exits 0 ONLY on a successful reply; exits 2 on connect failure,
# bad greeting or EOF without a reply, 3 on a QMP error reply.
qmp() {
  python3 - "$QMP" "$1" <<'PY'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
    f = s.makefile("rw")
    if "QMP" not in f.readline():
        sys.exit(2)
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
    if "return" not in f.readline():
        sys.exit(2)
    f.write(json.dumps({"execute": sys.argv[2]}) + "\n"); f.flush()
    for line in f:
        d = json.loads(line)
        if "return" in d:
            print(json.dumps(d["return"])); sys.exit(0)
        if "error" in d:
            print(json.dumps(d["error"]), file=sys.stderr); sys.exit(3)
    sys.exit(2)
except (OSError, ValueError) as e:
    print(str(e), file=sys.stderr); sys.exit(2)
PY
}
