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

# 5. lock (finding 5): live holder blocks, dead holder is reclaimed, lock released after
mkdir -p "$T/v5/lock"; sleep 120 & H=$!; echo $H > "$T/v5/lock/pid"
out=$(KDEVM_STATE="$T/v5" ./kdevm.sh down 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"another kdevm command"* ]] && pass "lock held by a live process blocks" || fail "lock held by a live process (rc=$rc)"
kill $H 2>/dev/null; wait $H 2>/dev/null
echo 999999 > "$T/v5/lock/pid"
KDEVM_STATE="$T/v5" ./kdevm.sh down >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && ! -d "$T/v5/lock" ]] && pass "dead lock holder reclaimed and lock released" || fail "dead lock reclaim (rc=$rc)"

# 5b. the lock must cover the whole operation and overlapping commands must serialise
mkdir -p "$T/v5b"
KDEVM_STATE="$T/v5b" ./kdevm.sh _lockprobe 3 > "$T/v5b/a.out" 2>&1 &
A=$!; sleep 0.5
[[ -d "$T/v5b/lock" ]] && pass "lock exists during the held section (script-scope trap)" || fail "lock already gone during the held section"
KDEVM_STATE="$T/v5b" ./kdevm.sh _lockprobe 3 > "$T/v5b/b.out" 2>&1; rcB=$?
wait $A; rcA=$?
if [[ $rcA -eq 0 && $rcB -ne 0 && "$(cat "$T/v5b/a.out")" == held && "$(cat "$T/v5b/b.out")" == *"another kdevm command"* ]]; then pass "overlapping commands: exactly one held the lock, the other was refused"; else fail "overlapping commands (A=$rcA B=$rcB)"; fi
[[ ! -d "$T/v5b/lock" ]] && pass "lock released after the holder exited" || fail "lock left behind after exit"
# 5c. exclusive stale-lock takeover: two contenders against one dead holder
mkdir -p "$T/v5c/lock"; echo 999999 > "$T/v5c/lock/pid"
KDEVM_STATE="$T/v5c" ./kdevm.sh _lockprobe 2 > "$T/v5c/a.out" 2>&1 & A=$!
KDEVM_STATE="$T/v5c" ./kdevm.sh _lockprobe 2 > "$T/v5c/b.out" 2>&1 & B=$!
wait $A; rcA=$?; wait $B; rcB=$?
n=$(cat "$T/v5c/a.out" "$T/v5c/b.out" | grep -c '^held$')
[[ $n -eq 1 ]] && pass "stale lock taken over by exactly one of two contenders" || fail "stale lock takeover: $n holders (A=$rcA B=$rcB)"

# 5d. an abandoned takeover marker (dead contender) does not wedge the lock forever
mkdir -p "$T/v5d/lock/takeover"; echo 999999 > "$T/v5d/lock/pid"; touch -t 202001010000 "$T/v5d/lock/takeover"
out=$(KDEVM_STATE="$T/v5d" ./kdevm.sh _lockprobe 0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == held ]] && pass "stale lock with an abandoned takeover marker recovered" || fail "abandoned marker (rc=$rc: $out)"
# 5e. a fresh marker inside a LIVE owner's lock must not let a contender steal it
mkdir -p "$T/v5e/lock/takeover"; sleep 120 & LH=$!; echo $LH > "$T/v5e/lock/pid"
out=$(KDEVM_STATE="$T/v5e" ./kdevm.sh _lockprobe 0 2>&1); rc=$?
[[ $rc -ne 0 && -d "$T/v5e/lock" && "$(cat "$T/v5e/lock/pid")" == "$LH" ]] && pass "live owner's lock not stolen despite a takeover marker" || fail "live owner stolen (rc=$rc)"
kill $LH 2>/dev/null; wait $LH 2>/dev/null
# 5f. a lock-refused factory build must not touch the active build's seed
mkdir -p "$T/v5f/lock"; sleep 120 & LH2=$!; echo $LH2 > "$T/v5f/lock/pid"; printf 'seed' > "$T/v5f/seed.iso"
out=$(KDEVM_STATE="$T/v5f" ./guest/build.sh 2>&1); rc=$?
[[ $rc -ne 0 && -f "$T/v5f/seed.iso" ]] && pass "refused builder left the active build's seed alone" || fail "refused builder removed the seed (rc=$rc)"
kill $LH2 2>/dev/null; wait $LH2 2>/dev/null

# 6. private permissions (finding 6): the state dir a command creates is 0700
[[ "$(stat -f %Lp "$T/v5")" == 700 || "$(stat -f %Lp "$T/v4")" == 700 ]] && pass "state directory created 0700" || fail "state directory mode"

# 7. YAML rendering (finding 7): hostile passwords and keys survive the template
if [[ -x .venv/bin/python ]] && .venv/bin/python -c 'import yaml' 2>/dev/null; then
  awk "/<<'PY'\$/{f=1; next} f && /^PY\$/{exit} f" guest/build.sh > "$T/render.py"
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
else
  echo "SKIP  failed-readiness probe (no qemu-img)"
fi

echo
[[ $fails -eq 0 ]] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
