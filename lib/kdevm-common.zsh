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
# whitespace so saved and live values compare equal. ps prints lstart in the
# caller's time zone and locale, so both are pinned: the Mac changing zone
# while the VM runs (travel) must not turn our QEMU into a stranger.
proc_start() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1; print}'; }
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
# One kernel-managed advisory lock per state directory (zsh/system's
# `zsystem flock`, stock zsh on macOS), taken by every state-changing verb,
# including the factory build, which runs as a function IN the process that
# took the lock (guest/factory.zsh). The lock lives on an open file
# descriptor of THIS process: the kernel releases it on normal exit, error,
# crash or SIGKILL, and a child that inherits the descriptor does not hold it
# (POSIX record-lock semantics, verified 2026-10-03). So there is nothing to
# release, no owner metadata, no stale lock and no takeover: if the lock is
# held, the other command is alive by definition; wait for it.
zmodload zsh/system 2>/dev/null || die "zsh/system module unavailable (kdevm needs the stock macOS zsh)"
take_lock() {
  install -d -m 700 "$STATE"
  LOCKFILE="$STATE/lock"
  : >> "$LOCKFILE"
  if ! zsystem flock -f KDEVM_LOCK_FD -t 0 "$LOCKFILE" 2>/dev/null; then
    die "another kdevm command is running on $STATE; wait for it"
  fi
}

# take_tree_lock FILE: an exclusive lock on a directory tree that is held for
# as long as this process OR ANY PROCESS IT STARTS is alive. The lifecycle
# lock above belongs to one process, which is right for kdevm.sh; a build
# hands its tree to compilers that can outlive it. flock(2) locks belong to
# the open file, and children inherit the descriptor, so the kernel keeps
# the lock until the last of them has ended. Returns 1 if it is held.
take_tree_lock() {
  local fd
  exec {fd}>>"$1" || return 1
  python3 -c 'import fcntl, sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)' $fd 2>/dev/null
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
