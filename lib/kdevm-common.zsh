# kdevm shared library. Sourced (zsh) by kdevm.sh, guest/build.sh,
# runtime/build.sh and tests/checks.sh. Callers set KDEVM_TOOL (message
# prefix) before sourcing, STATE before using the lock, QMP before using qmp.

KDEVM_LIB=${${(%):-%x}:A}   # this file; a launched process sources it to register itself
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

# ---- tracked processes -----------------------------------------------------
# launch_tracked RECORD LOG COMMAND...: start COMMAND in the background as a
# process that has registered itself in RECORD before it exists.
#
# The record file is created HERE, by the caller (which holds the lifecycle
# lock), and handed to a small launcher as an open descriptor. The launcher
# writes its own pid and start time through that descriptor and then execs
# COMMAND, which keeps both. Consequences:
#   - no COMMAND ever runs without a record, whatever happens to the caller;
#   - if the start time cannot be read or written, COMMAND is never started,
#     so there is never an unrecorded process to clean up by pid;
#   - a launcher that is delayed until a later launch has replaced RECORD
#     writes into its own, now unlinked, file and cannot touch the new one;
#     it then sees that RECORD is no longer its file and does not exec.
# The launcher's stdout and stderr, and COMMAND's, are appended to LOG.
# Returns 1, with nothing started, if RECORD cannot be created.
launch_tracked() { # record, log, command...
  local rec=$1 logf=$2 rfd; shift 2
  rm -f "$rec" 2>/dev/null || true
  # A new file every time (creat,excl), opened here: no record file, no process.
  sysopen -w -o creat,excl -u rfd -- "$rec" 2>/dev/null || return 1
  zsh -c 'lib=$1 rec=$2 lockfd=$3; shift 3
          [[ -n "$lockfd" ]] && exec {lockfd}>&-
          source "$lib" && zmodload -F zsh/stat b:zstat && start=$(proc_start $$) && [[ -n "$start" ]] \
            && print -r -- "$$ $start" >&3 && [[ "$(zstat +inode -f 3)" == "$(zstat +inode -- "$rec" 2>/dev/null)" ]] \
            && exec 3>&- && exec "$@"
          print -u2 -r -- "kdevm: could not record this process and its start time in $rec; not started: $1"; exit 1' \
    kdevm-launch "$KDEVM_LIB" "$rec" "${KDEVM_LOCK_FD:-}" "$@" </dev/null >>"$logf" 2>&1 3>&$rfd {rfd}>&- &
  exec {rfd}>&-
}

# stop_tracked RECORD PATTERN LABEL [kill]: end the process RECORD vouches for.
# Every signal is sent only after the record has been checked against the
# live process (command line and start time), immediately before it:
#   running -> SIGTERM, wait; with "kill", SIGKILL if it is still ours, wait;
#   absent  -> nothing to signal;
#   unknown -> nothing is signalled.
# The record is removed only once the process is confirmed gone (or was
# never ours). Returns 1, record kept, if it could not be verified or did
# not end.
stop_tracked() { # record, pattern, label, [kill]
  local rec=$1 pat=$2 label=$3 PF_PID PF_START i
  read_pidfile "$rec" || { rm -f "$rec" 2>/dev/null || true; return 0; }   # empty or unreadable: nothing was ever registered
  case "$(pid_state "$PF_PID" "$PF_START" "$pat")" in
    absent)  rm -f "$rec"; return 0 ;;
    unknown) log "$label pid $PF_PID could not be verified (process inspection failed); not signalled, tracking preserved"; return 1 ;;
  esac
  kill "$PF_PID" 2>/dev/null || true
  for i in {1..25}; do [[ "$(pid_state "$PF_PID" "$PF_START" "$pat")" == absent ]] && break; sleep 0.2; done
  if [[ "${4:-}" == kill && "$(pid_state "$PF_PID" "$PF_START" "$pat")" == running ]]; then
    kill -9 "$PF_PID" 2>/dev/null || true
    for i in {1..25}; do [[ "$(pid_state "$PF_PID" "$PF_START" "$pat")" == absent ]] && break; sleep 0.2; done
  fi
  if [[ "$(pid_state "$PF_PID" "$PF_START" "$pat")" != absent ]]; then
    log "$label pid $PF_PID did not exit after ${${4:+SIGTERM and SIGKILL}:-SIGTERM}; tracking preserved"; return 1
  fi
  rm -f "$rec"
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
