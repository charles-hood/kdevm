#!/bin/zsh
# Offline checks for kdevm: no VM is started, the real state directory is
# never touched (every probe uses a throwaway KDEVM_STATE under $TMPDIR).
# These are the probes from the 0.1.0 code review, kept so they stay true.
#
#   tests/checks.sh            run everything; exit 1 on any FAIL
#
# The YAML probe needs PyYAML: python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
KDEVM_TOOL=tests
source "$REPO/lib/kdevm-common.zsh"
kdevm_load_env
T="$(mktemp -d "${TMPDIR:-/tmp}/kdevm-checks.XXXXXX")"
trap 'rm -rf "$T"' EXIT
# Fixtures so no builder invocation can touch the user's real password or key.
mkdir -p "$T/fx"; printf 'fixture-password' > "$T/fx/password"; chmod 600 "$T/fx/password"
printf 'ssh-ed25519 AAAAFIXTURE checks\n' > "$T/fx/key.pub"
export KDEVM_PASS_FILE="$T/fx/password" KDEVM_SSH_PUB="$T/fx/key.pub"
# Offline, inside the fixture: the runtime builder and the base-image download
# refuse under KDEVM_OFFLINE=1, and any scratch work would land in $T.
export KDEVM_OFFLINE=1 KDEVM_SCRATCH="$T/scratch"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
need_runtime() { [[ -x "${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current/bin/qemu-system-aarch64" ]]; }

# 0. syntax
for f in kdevm.sh guest/build.sh runtime/build.sh lib/kdevm-common.zsh tests/checks.sh; do
  zsh -n "$f" && pass "zsh -n $f" || fail "zsh -n $f"
done
python3 -c 'compile(open("guest/vendor/omarchy-native-clipboard-bridge").read(), "agent", "exec")' 2>/dev/null && pass "vendored clipboard agent compiles (in memory, no bytecode written)" || fail "vendored clipboard agent compiles"
python3 -c 'import json; json.load(open("guest/files/firefox-policies.json"))' && pass "firefox policies.json parses" || fail "firefox policies.json parses"

# 1. password generation (review finding 1): no tr|head pipeline, 20 chars, mode 600, reused on a second run
if need_runtime; then
  mkdir -p "$T/v1"
  KDEVM_STATE="$T/v1/state" KDEVM_PASS_FILE="$T/v1/cfg/password" KDEVM_SSH_PUB=/nonexistent ./guest/build.sh >/dev/null 2>&1
  if [[ -f "$T/v1/cfg/password" && "$(stat -f %Lp "$T/v1/cfg/password")" == 600 && "$(wc -c < "$T/v1/cfg/password" | tr -d ' ')" == 20 ]]; then pass "password generated, 20 chars, mode 600"; else fail "password generation"; fi
  out=$(KDEVM_STATE="$T/v1/state" KDEVM_PASS_FILE="$T/v1/cfg/password" KDEVM_SSH_PUB=/nonexistent ./guest/build.sh 2>&1)
  [[ "$out" != *generated* ]] && pass "existing password reused" || fail "existing password reused"
else
  echo "SKIP  password generation (no runtime staged; guest/build.sh checks for it first)"
fi

# 3. factory --force refuses while an overlay exists (finding 3)
if need_runtime; then
  mkdir -p "$T/v3"; : > "$T/v3/factory.qcow2"; : > "$T/v3/work.qcow2"
  out=$(KDEVM_STATE="$T/v3" KDEVM_PASS_FILE="$T/fx/password" KDEVM_SSH_PUB="$T/fx/key.pub" ./guest/build.sh --force 2>&1); rc=$?
  if [[ $rc -ne 0 && "$out" == *overlay* && ! -e "$T/v3/factory.qcow2.building" ]]; then pass "factory --force refused while an overlay exists"; else fail "factory --force with overlay (rc=$rc)"; fi
else
  echo "SKIP  factory --force probe (no runtime staged)"
fi

# 4. stale pid files are not trusted (finding 4): a sleeper must survive down/status
mkdir -p "$T/v4"; sleep 120 & SL=$!
echo $SL > "$T/v4/qemu.pid"; echo $SL > "$T/v4/clipboard-bridge.pid"
KDEVM_STATE="$T/v4" ./kdevm.sh down >/dev/null 2>&1
KDEVM_STATE="$T/v4" ./kdevm.sh status >/dev/null 2>&1
if kill -0 $SL 2>/dev/null; then pass "stale pid: unrelated process left alive"; else fail "stale pid: unrelated process was signalled"; fi
[[ ! -e "$T/v4/qemu.pid" ]] && pass "stale qemu.pid removed" || fail "stale qemu.pid kept"
kill $SL 2>/dev/null; wait $SL 2>/dev/null
# 4b. a bridge pid whose process merely mentions kdevm (an editor) must not be signalled
mkdir -p "$T/v4b"; ARGV0="vim /review/kdevm.sh" zsh -c 'sleep 120; :' & ED=$!; sleep 0.3
echo "$ED $(ps -o lstart= -p $ED | awk '{$1=$1; print}')" > "$T/v4b/clipboard-bridge.pid"
KDEVM_STATE="$T/v4b" ./kdevm.sh down >/dev/null 2>&1
if kill -0 $ED 2>/dev/null; then pass "bridge pid: unrelated 'vim kdevm.sh' process left alive"; else fail "bridge pid: unrelated process was signalled"; fi
kill $ED 2>/dev/null; wait $ED 2>/dev/null
# 4c. the real supervisor identity IS accepted (same argv[0] shape, same start time)
mkdir -p "$T/v4c"; ARGV0="kdevm-bridge-supervisor 1" zsh -c 'sleep 120; :' & SV=$!; sleep 0.3
echo "$SV $(ps -o lstart= -p $SV | awk '{$1=$1; print}')" > "$T/v4c/clipboard-bridge.pid"
KDEVM_STATE="$T/v4c" ./kdevm.sh down >/dev/null 2>&1
if kill -0 $SV 2>/dev/null; then fail "bridge pid: a genuine supervisor was not signalled"; else pass "bridge pid: genuine supervisor identity accepted and stopped"; fi
kill $SV 2>/dev/null; wait $SV 2>/dev/null


# 4d. a record without a start time is never ours: sleeper survives, record dropped
mkdir -p "$T/v4d"; sleep 120 & SL2=$!; echo "$SL2" > "$T/v4d/qemu.pid"
KDEVM_STATE="$T/v4d" ./kdevm.sh down >/dev/null 2>&1
kill -0 $SL2 2>/dev/null && pass "pid record without start time: process left alive" || fail "pid record without start time: signalled"
[[ ! -e "$T/v4d/qemu.pid" ]] && pass "pid record without start time discarded" || fail "pid record without start time kept"
kill $SL2 2>/dev/null; wait $SL2 2>/dev/null
# 4e. inspection failure (ps broken) keeps the record, refuses the verb, signals nothing
mkdir -p "$T/v4e" "$T/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/ps"; chmod +x "$T/fakebin/ps"
sleep 120 & SL3=$!; echo "$SL3 $(ps -o lstart= -p $SL3 | awk '{$1=$1; print}')" > "$T/v4e/qemu.pid"
out=$(PATH="$T/fakebin:$PATH" KDEVM_STATE="$T/v4e" ./kdevm.sh down 2>&1); rc=$?
if [[ $rc -ne 0 && "$out" == *"cannot be inspected"* && -e "$T/v4e/qemu.pid" ]] && kill -0 $SL3 2>/dev/null; then pass "inspection failure: record kept, verb refused, process untouched"; else fail "inspection failure handling (rc=$rc)"; fi
out=$(PATH="$T/fakebin:$PATH" KDEVM_STATE="$T/v4e" ./kdevm.sh status 2>&1)
[[ "$out" == *UNKNOWN* ]] && pass "status reports UNKNOWN when inspection fails" || fail "status on inspection failure"
kill $SL3 2>/dev/null; wait $SL3 2>/dev/null

# 4f. command inspection succeeds but the start-time lookup fails or is empty: unknown, not absent
mkdir -p "$T/v4f" "$T/fakebin2"
cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
# answers -o command= normally, fails -o lstart=
for a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done
exec /bin/ps "$@"
EOF
chmod +x "$T/fakebin2/ps"
sleep 120 & SL4=$!; echo "$SL4 $(ps -o lstart= -p $SL4 | awk '{$1=$1; print}')" > "$T/v4f/qemu.pid"
st=$(PATH="$T/fakebin2:$PATH" zsh -c "source $REPO/lib/kdevm-common.zsh; pid_state $SL4 'x' 'sleep*'")
[[ "$st" == unknown ]] && pass "pid_state: start-time lookup failure after a matching command is unknown" || fail "pid_state start-time failure gave '$st'"
cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "lstart=" ] && exit 0; done
exec /bin/ps "$@"
EOF
st=$(PATH="$T/fakebin2:$PATH" zsh -c "source $REPO/lib/kdevm-common.zsh; pid_state $SL4 'x' 'sleep*'")
[[ "$st" == unknown ]] && pass "pid_state: empty start-time output is unknown" || fail "pid_state empty start gave '$st'"
st=$(zsh -c "source $REPO/lib/kdevm-common.zsh; pid_state $SL4 'not-the-start' 'sleep*'")
[[ "$st" == absent ]] && pass "pid_state: same command, different start time is absent (reused pid)" || fail "pid_state different start gave '$st'"
kill $SL4 2>/dev/null; wait $SL4 2>/dev/null

# 4g. clipboard supervisor whose start time cannot be inspected during down:
#     not signalled, record kept, reported (down exits 2), not converted to absent
mkdir -p "$T/v4g"; ARGV0="kdevm-bridge-supervisor 1" zsh -c 'sleep 120; :' & SV2=$!; sleep 0.3
echo "$SV2 $(ps -o lstart= -p $SV2 | awk '{$1=$1; print}')" > "$T/v4g/clipboard-bridge.pid"
cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done
exec /bin/ps "$@"
EOF
out=$(PATH="$T/fakebin2:$PATH" KDEVM_STATE="$T/v4g" ./kdevm.sh down 2>&1); rc=$?
if kill -0 $SV2 2>/dev/null && [[ -f "$T/v4g/clipboard-bridge.pid" && $rc -eq 2 && "$out" == *"could not be verified"* && "$out" == *"tracking preserved"* ]]; then pass "supervisor unknown during down: not signalled, record kept, reported"; else fail "supervisor unknown during down (rc=$rc alive=$(kill -0 $SV2 2>/dev/null && echo yes || echo no) record=$([[ -f "$T/v4g/clipboard-bridge.pid" ]] && echo kept || echo removed))"; fi
out=$(KDEVM_STATE="$T/v4g" ./kdevm.sh down 2>&1); rc=$?
if ! kill -0 $SV2 2>/dev/null && [[ ! -f "$T/v4g/clipboard-bridge.pid" && $rc -eq 0 ]]; then pass "same supervisor with inspection working again: stopped, exit confirmed, record removed"; else fail "supervisor stop after recovery (rc=$rc)"; kill $SV2 2>/dev/null; fi

# 4h. status reports an UNKNOWN supervisor (record kept) in all three QEMU states.
#     A ps wrapper fails the start-time lookup only for the pid in KDEVM_TEST_UNKNOWN_PID.
cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
hit=0; for a in "$@"; do [ "$a" = "lstart=" ] && hit=1; done
if [ "$hit" = 1 ] && [ -n "$KDEVM_TEST_UNKNOWN_PID" ]; then for a in "$@"; do [ "$a" = "$KDEVM_TEST_UNKNOWN_PID" ] && exit 1; done; fi
exec /bin/ps "$@"
EOF
mkdir -p "$T/v4h" "$T/fakert4/current/bin"; : > "$T/fakert4/current/bin/qemu-system-aarch64"; : > "$T/fakert4/current/bin/omarchy-vm-helper"; chmod +x "$T/fakert4/current/bin/"*
# Network isolation for this fixture: status probes the ssh port with `nc`
# and, if it answers, runs diagnostics over `ssh`. Both are called by bare
# name, so stubs first in PATH intercept every call; the stubs log and fail
# (port "not answering", ssh exit 255), and nothing can reach a real service.
mkdir -p "$T/netstub"
printf '#!/bin/sh\necho "nc $*" >> "$KDEVM_TEST_NETLOG"; exit 1\n' > "$T/netstub/nc"
printf '#!/bin/sh\necho "ssh $*" >> "$KDEVM_TEST_NETLOG"; exit 255\n' > "$T/netstub/ssh"
chmod +x "$T/netstub/nc" "$T/netstub/ssh"; export KDEVM_TEST_NETLOG="$T/v4h/netlog"; : > "$KDEVM_TEST_NETLOG"
ARGV0="kdevm-bridge-supervisor 1" zsh -c 'sleep 120; :' & SV3=$!; sleep 0.3
echo "$SV3 $(ps -o lstart= -p $SV3 | awk '{$1=$1; print}')" > "$T/v4h/clipboard-bridge.pid"
st_ok=1
check_status() { # label, expected qemu line fragment
  local out; out=$(PATH="$T/netstub:$T/fakebin2:$PATH" KDEVM_TEST_UNKNOWN_PID="${3:-$SV3}" KDEVM_STATE="$T/v4h" KDEVM_RUNTIME_ROOT="$T/fakert4" ./kdevm.sh status 2>&1)
  if [[ "$out" == *"clipboard bridge: UNKNOWN"* && "$out" == *"$2"* && -f "$T/v4h/clipboard-bridge.pid" ]] && kill -0 $SV3 2>/dev/null; then pass "status: supervisor UNKNOWN reported and record kept with QEMU $1"; else st_ok=0; fail "status with QEMU $1: $(echo "$out" | grep -E 'qemu:|bridge' | tr '\n' ' ')"; fi
}
# (a) QEMU absent: no qemu.pid
check_status absent "qemu: not running"
# (b) QEMU running: a process whose command line matches the runtime QEMU on this state's overlay
ARGV0="$T/fakert4/current/bin/qemu-system-aarch64 -drive file=$T/v4h/work.qcow2" zsh -c 'sleep 120; :' & FQ=$!; sleep 0.3
echo "$FQ $(ps -o lstart= -p $FQ | awk '{$1=$1; print}')" > "$T/v4h/qemu.pid"
check_status running "qemu: pid $FQ"
# (c) QEMU unknown: its own start-time lookup fails too (wrapper fails every lstart)
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done\nexec /bin/ps "$@"\n' > "$T/fakebin2/ps"
check_status unknown "qemu: UNKNOWN"
[[ -f "$T/v4h/qemu.pid" ]] && pass "status: QEMU record kept while unknown" || fail "status dropped the QEMU record while unknown"
# isolation proof: the running-QEMU case probed the port through the stub (logged, "not answering"),
# so ssh was never attempted, and no real nc or ssh ran (the stubs shadow them for every call)
if grep -q '^nc .*localhost' "$KDEVM_TEST_NETLOG" && ! grep -q '^ssh ' "$KDEVM_TEST_NETLOG"; then pass "status fixture: port probe intercepted by the nc stub, ssh never attempted, no real service contacted"; else fail "status fixture network isolation (log: $(tr '\n' ';' < "$KDEVM_TEST_NETLOG"))"; fi
unset KDEVM_TEST_NETLOG
kill $SV3 $FQ 2>/dev/null; wait $SV3 $FQ 2>/dev/null

# 5. lock (finding 5): kernel advisory lock (zsystem flock), held for the
#    command's lifetime, released by the OS however the holder ends
# 5a. two concurrent lifecycle commands: exactly one proceeds
mkdir -p "$T/v5"
KDEVM_STATE="$T/v5" ./kdevm.sh _lockprobe 3 > "$T/v5/a.out" 2>&1 & A=$!; sleep 0.5
KDEVM_STATE="$T/v5" ./kdevm.sh _lockprobe 3 > "$T/v5/b.out" 2>&1; rcB=$?
wait $A; rcA=$?
if [[ $rcA -eq 0 && $rcB -ne 0 && "$(cat "$T/v5/a.out")" == held && "$(cat "$T/v5/b.out")" == *"another kdevm command is running"* ]]; then pass "two concurrent commands: one held the lock, the other was refused"; else fail "concurrent commands (A=$rcA B=$rcB)"; fi
# 5b. abnormal death of the holder (SIGKILL), then acquisition succeeds at once
KDEVM_STATE="$T/v5" ./kdevm.sh _lockprobe 60 > "$T/v5/c.out" 2>&1 & C=$!; sleep 0.5
[[ "$(cat "$T/v5/c.out")" == held ]] || fail "holder did not take the lock"
kill -9 $C; wait $C 2>/dev/null
out=$(KDEVM_STATE="$T/v5" ./kdevm.sh _lockprobe 0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == held ]] && pass "holder SIGKILLed: next command acquired the lock immediately, nothing to clean" || fail "after SIGKILL (rc=$rc: $out)"
# 5c. a detached child that inherited the holder's descriptors does not keep the lock
out=$(KDEVM_STATE="$T/v5" ./kdevm.sh _lockprobe_spawn 2>&1); child="${out#held }"
out2=$(KDEVM_STATE="$T/v5" ./kdevm.sh _lockprobe 0 2>&1); rc=$?
if [[ $rc -eq 0 && "$out2" == held ]] && kill -0 "$child" 2>/dev/null; then pass "lock is per process: free after the holder exits although its child lives on"; else fail "inherited descriptor kept the lock (rc=$rc)"; fi
kill "$child" 2>/dev/null
# 5d. the lock file is private and no owner metadata exists
[[ "$(stat -f %Lp "$T/v5/lock")" == 600 && ! -d "$T/v5/lock" ]] && pass "lock is a 0600 file, no pid metadata" || fail "lock file mode/type"

# 5f. a factory build refused by a REAL lock holder must not touch the active build's seed
mkdir -p "$T/v5f"; printf 'seed' > "$T/v5f/seed.iso"
KDEVM_STATE="$T/v5f" ./kdevm.sh _lockprobe 4 > /dev/null 2>&1 & LH2=$!; sleep 0.5
out=$(KDEVM_STATE="$T/v5f" ./guest/build.sh 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"another kdevm command is running"* && -f "$T/v5f/seed.iso" ]] && pass "builder refused by a live flock holder; the holder's seed untouched" || fail "refused builder (rc=$rc: $out)"
wait $LH2 2>/dev/null

# 6. private permissions (finding 6): the state dir a command creates is 0700
[[ "$(stat -f %Lp "$T/v5")" == 700 || "$(stat -f %Lp "$T/v4")" == 700 ]] && pass "state directory created 0700" || fail "state directory mode"

# 7. YAML rendering (finding 7): hostile passwords and keys survive the template
if [[ -x .venv/bin/python ]] && .venv/bin/python -c 'import yaml' 2>/dev/null; then
  awk "/<<'PY'\$/{f=1; next} f && /^PY\$/{exit} f" guest/factory.zsh > "$T/render.py"
  V=guest/vendor; ok=1
  for pw in '&secret' '|secret' 'abc #secret' '12345678' 'q"uo\te' "it's" '{a: b}' '- dash' 'tab	here' ' leading space' 'üñî©ødé' '\\backslash' 'a\nb' 'pass🔑word'; do
    KDEVM_USER_NAME=tester KDEVM_PASS="$pw" KDEVM_SSHKEY='ssh-ed25519 AAAATEST comment #with: odd & chars' \
      python3 "$T/render.py" guest/user-data.yaml.tmpl "$T/ud.yaml" "$V/omarchy-native-clipboard-bridge" \
      "$V/omarchy-native-clipboard-bridge.service" "$V/92-omarchy-native-clipboard.rules" \
      "$V/90-try-omarchy-quantum.conf" guest/files/firefox-policies.json || { ok=0; continue; }
    KDEVM_PASS="$pw" .venv/bin/python -c 'import yaml,os,sys; d=yaml.safe_load(open(sys.argv[1])); u=d["users"][0]; sys.exit(0 if u["plain_text_passwd"]==os.environ["KDEVM_PASS"] and u["ssh_authorized_keys"][0]=="ssh-ed25519 AAAATEST comment #with: odd & chars" else 1)' "$T/ud.yaml" || { ok=0; echo "      password case failed: ${(q)pw}"; }
  done
  [[ $ok -eq 1 ]] && pass "14 hostile passwords (incl. non-BMP) and a hostile key round-trip through YAML" || fail "YAML rendering"
else
  echo "SKIP  YAML rendering (no .venv with PyYAML; see header)"
fi

# 8. config loader: any NAME=value is read, an explicit (even empty) variable wins
mkdir -p "$T/home/.config/kdevm"; printf 'QEMU_IMG=/custom/qemu-img\nKDEVM_USER=fromfile\nKDEVM_MEM_MB=1234\n' > "$T/home/.config/kdevm/env"
got=$(HOME="$T/home" KDEVM_USER= zsh -c "source $REPO/lib/kdevm-common.zsh; kdevm_load_env; print -r -- \"\${QEMU_IMG}|\${KDEVM_USER-unset}|\${KDEVM_MEM_MB}\"")
[[ "$got" == "/custom/qemu-img||1234" ]] && pass "config loader: non-KDEVM keys kept, explicit empty value respected" || fail "config loader ($got)"


# 9. QMP helper strictness: success only on a "return"; EOF and error replies fail
qmp_server() { # socket mode(close|error|ok)
  python3 - "$1" "$2" <<'PYQ' &
import json, os, socket, sys
path, mode = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(1); srv.settimeout(10)
c, _ = srv.accept(); f = c.makefile("rw")
f.write(json.dumps({"QMP": {"version": {}, "capabilities": []}}) + "\n"); f.flush()
f.readline(); f.write(json.dumps({"return": {}}) + "\n"); f.flush()
cmd = json.loads(f.readline())
if mode == "close": c.close(); sys.exit(0)
if mode == "error": f.write(json.dumps({"error": {"class": "GenericError", "desc": "nope"}}) + "\n"); f.flush()
if mode == "ok": f.write(json.dumps({"return": {"status": "running", "running": True}}) + "\n"); f.flush()
c.close()
PYQ
  sleep 0.3
}
for mode in close error ok; do
  QMP="$T/qmp-$mode.sock"; qmp_server "$QMP" "$mode"; SV=$!
  out=$(qmp query-status 2>/dev/null); rc=$?; wait $SV 2>/dev/null
  case $mode in
    ok)    [[ $rc -eq 0 && "$out" == *'"running": true'* ]] && pass "qmp: success on a proper reply" || fail "qmp ok (rc=$rc)" ;;
    close) [[ $rc -ne 0 ]] && pass "qmp: EOF without a reply fails" || fail "qmp EOF accepted" ;;
    error) [[ $rc -ne 0 ]] && pass "qmp: error reply fails" || fail "qmp error accepted" ;;
  esac
done

# 10. failed readiness: a fake QEMU that opens its sockets but never answers QMP
#     is terminated by up, which exits non-zero and leaves no pid file.
QI="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
if [[ -x "$QI" ]]; then
  FRT="$T/fakert/current"; mkdir -p "$FRT/bin" "$T/v10"
  cat > "$FRT/bin/qemu-system-aarch64" <<'EOF'
#!/bin/zsh
# fake QEMU: bind the QMP and clipboard sockets named on the command line, then hang
qmp=""; clip=""
for a in "$@"; do
  [[ "$a" == unix:*,server=on,wait=off ]] && { qmp="${a#unix:}"; qmp="${qmp%%,*}"; }
  [[ "$a" == socket,id=clip,path=* ]] && { clip="${a#socket,id=clip,path=}"; clip="${clip%%,*}"; }
done
python3 - "$qmp" "$clip" <<'PYF'
import socket, sys, time, os
ss = []
for p in sys.argv[1:]:
    if not p: continue
    try: os.unlink(p)
    except FileNotFoundError: pass
    s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1); ss.append(s)
time.sleep(120)
PYF
EOF
  chmod +x "$FRT/bin/qemu-system-aarch64"
  printf '#!/bin/sh\necho 48000\n' > "$FRT/bin/omarchy-vm-helper"; chmod +x "$FRT/bin/omarchy-vm-helper"
  "$QI" create -q -f qcow2 "$T/v10/factory.qcow2" 1M
  : > "$T/v10/code.fd"; : > "$T/v10/vars.fd"
  out=$(KDEVM_STATE="$T/v10" KDEVM_RUNTIME_ROOT="$T/fakert" KDEVM_FW_CODE="$T/v10/code.fd" KDEVM_FW_VARS="$T/v10/vars.fd" KDEVM_SHARE="$T/v10/share" KDEVM_WINDOW=keep ./kdevm.sh up 2>&1); rc=$?
  left=$(pgrep -f "$FRT/bin/qemu-system-aarch64" || true)
  if [[ $rc -ne 0 && -z "$left" && ! -e "$T/v10/qemu.pid" && "$out" == *"failed to start"* ]]; then pass "failed readiness: fake QEMU terminated, non-zero exit, no pid file"; else fail "failed readiness (rc=$rc, leftover='$left')"; [[ -n "$left" ]] && kill $left 2>/dev/null; fi
  # 10b. start-time capture fails right after launch: the child is terminated, not orphaned
  rm -rf "$T/v10/run" "$T/v10/work.qcow2" "$T/v10/vars.fd"; : > "$T/v10/vars.fd"
  cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done
exec /bin/ps "$@"
EOF
  out=$(PATH="$T/fakebin2:$PATH" KDEVM_STATE="$T/v10" KDEVM_RUNTIME_ROOT="$T/fakert" KDEVM_FW_CODE="$T/v10/code.fd" KDEVM_FW_VARS="$T/v10/vars.fd" KDEVM_SHARE="$T/v10/share" KDEVM_WINDOW=keep ./kdevm.sh up 2>&1); rc=$?
  left=$(pgrep -f "$FRT/bin/qemu-system-aarch64" || true)
  if [[ $rc -ne 0 && -z "$left" && ! -e "$T/v10/qemu.pid" && "$out" == *"start time"* ]]; then pass "launch-time start capture failure: child terminated, no pid file"; else fail "start capture failure (rc=$rc, leftover='$left')"; [[ -n "$left" ]] && kill $left 2>/dev/null; fi
else
  echo "SKIP  failed-readiness probe (no qemu-img)"
fi


# 11. wrapper-driven factory execution: kdevm.sh factory runs the build in ITS
#     OWN process while holding the lock (no delegated builder). A fake QEMU
#     records its parent pid and whether the state lock is held, then exits.
QI="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
if [[ -x "$QI" ]] && command -v mkisofs >/dev/null; then
  F2="$T/fakert2/current/bin"; mkdir -p "$F2" "$T/v11"
  cat > "$F2/qemu-system-aarch64" <<'EOF'
#!/bin/zsh
# fake provisioning QEMU: who launched me, is the lock held, then fail fast
echo $PPID > "$KDEVM_STATE/fakeqemu.ppid"
zmodload zsh/system
if zsystem flock -t 0 "$KDEVM_STATE/lock" 2>/dev/null; then echo free; else echo held; fi > "$KDEVM_STATE/fakeqemu.lock"
[[ -n "${KDEVM_FAKE_QEMU_SLEEP:-}" ]] && sleep "$KDEVM_FAKE_QEMU_SLEEP"
exit 1
EOF
  chmod +x "$F2/qemu-system-aarch64"
  printf '#!/bin/sh\necho 48000\n' > "$F2/omarchy-vm-helper"; chmod +x "$F2/omarchy-vm-helper"   # every runtime executable: no fallback to the real builder
  "$QI" create -q -f qcow2 "$T/v11/debian-13-generic-arm64.qcow2" 1M
  printf '%s  debian-13-generic-arm64.qcow2\n' "$(shasum -a 512 "$T/v11/debian-13-generic-arm64.qcow2" | cut -d' ' -f1)" > "$T/v11/SHA512SUMS"
  : > "$T/v11/code.fd"; : > "$T/v11/vars.fd"
  KDEVM_STATE="$T/v11" KDEVM_RUNTIME_ROOT="$T/fakert2" KDEVM_FW_CODE="$T/v11/code.fd" KDEVM_FW_VARS="$T/v11/vars.fd" KDEVM_SSH_PORT=2299 \
    ./kdevm.sh factory > "$T/v11/out" 2>&1 & W=$!
  wait $W; rc=$?
  ppid=$(cat "$T/v11/fakeqemu.ppid" 2>/dev/null); lk=$(cat "$T/v11/fakeqemu.lock" 2>/dev/null)
  if [[ $rc -ne 0 && "$ppid" == "$W" && "$lk" == held && "$(cat "$T/v11/out")" == *"QEMU exited during provisioning"* ]]; then pass "kdevm.sh factory: provisioning QEMU launched by the lock-holding kdevm.sh process itself (ppid $W), lock held"; else fail "wrapper-driven factory (rc=$rc ppid=$ppid wrapper=$W lock=$lk)"; fi
  [[ -f "$T/v11/factory.qcow2.failed" && ! -e "$T/v11/seed.iso" && ! -e "$T/v11/factory.qcow2.building" ]] && pass "failed build: disk kept as .failed, seed removed" || fail "failed build cleanup"
  # a builder process is a zsh running one of the two scripts, not any command line that mentions them
  pgrep -f '^(/bin/)?zsh .*guest/build\.sh' >/dev/null && fail "a separate guest/build.sh process exists" || pass "no separate builder process was involved"
  [[ "$(cat "$T/v11/out")" != *"runtime build requested"* && ! -d "$T/scratch/try-omarchy" ]] && pass "factory probe never reached runtime/build.sh (no scratch checkout)" || fail "factory probe reached the runtime builder"
  # 11b. an incomplete runtime (helper missing) under KDEVM_OFFLINE=1 must fail loudly before any fetch
  F3="$T/fakert3/current/bin"; mkdir -p "$F3" "$T/v11b"; cp "$F2/qemu-system-aarch64" "$F3/"
  out=$(KDEVM_STATE="$T/v11b" KDEVM_RUNTIME_ROOT="$T/fakert3" KDEVM_FW_CODE="$T/v11/code.fd" KDEVM_FW_VARS="$T/v11/vars.fd" ./kdevm.sh factory 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"runtime build requested while KDEVM_OFFLINE=1"* && ! -d "$T/scratch/try-omarchy" ]] && pass "incomplete runtime fixture: builder refused immediately under KDEVM_OFFLINE, nothing fetched" || fail "offline guard (rc=$rc: $out)"

  # 12. abnormal death of the lock-owning process during a build: nothing
  #     continues mutating shared state, the lock is free, and a leftover
  #     provisioning VM keeps the next factory build fail-closed.
  rm -f "$T/v11/fakeqemu.ppid" "$T/v11/fakeqemu.lock" "$T/v11/factory.qcow2.failed"
  KDEVM_STATE="$T/v11" KDEVM_RUNTIME_ROOT="$T/fakert2" KDEVM_FW_CODE="$T/v11/code.fd" KDEVM_FW_VARS="$T/v11/vars.fd" KDEVM_SSH_PORT=2299 KDEVM_FAKE_QEMU_SLEEP=60 \
    ./kdevm.sh factory > "$T/v11/out2" 2>&1 & W2=$!
  for i in {1..100}; do [[ -f "$T/v11/fakeqemu.ppid" ]] && break; sleep 0.1; done
  kill -9 $W2; wait $W2 2>/dev/null; sleep 0.3
  orphan=$(pgrep -f "$F2/qemu-system-aarch64" || true)
  builders=$(pgrep -f -l '^(/bin/)?zsh .*(kdevm\.sh factory|guest/build\.sh)' || true)
  [[ -z "$builders" ]] && pass "holder SIGKILLed mid-build: no builder process continues" || fail "a builder continued: $builders"
  out=$(KDEVM_STATE="$T/v11" ./kdevm.sh _lockprobe 0 2>&1); rc=$?
  [[ $rc -eq 0 && "$out" == held ]] && pass "lock free immediately after the holder's death" || fail "lock not free after SIGKILL (rc=$rc)"
  out=$(KDEVM_STATE="$T/v11" KDEVM_RUNTIME_ROOT="$T/fakert2" KDEVM_FW_CODE="$T/v11/code.fd" KDEVM_FW_VARS="$T/v11/vars.fd" KDEVM_SSH_PORT=2299 ./kdevm.sh factory 2>&1); rc=$?
  if [[ -n "$orphan" ]]; then
    [[ $rc -ne 0 && "$out" == *"a kdevm VM is running"* ]] && pass "orphaned provisioning VM: next factory build refuses (fail-closed guard)" || fail "orphan guard (rc=$rc: $out)"
    kill $orphan 2>/dev/null
  else
    echo "SKIP  orphan guard (fake QEMU did not outlive the holder)"
  fi
else
  echo "SKIP  wrapper-driven factory probes (need qemu-img and mkisofs)"
fi

echo
[[ $fails -eq 0 ]] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
