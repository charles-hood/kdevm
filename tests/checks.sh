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
need_runtime() { [[ -x "${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current/bin/kdevm" ]]; }

# 0. syntax
for f in kdevm.sh guest/build.sh runtime/build.sh lib/kdevm-common.zsh tests/checks.sh; do
  zsh -n "$f" && pass "zsh -n $f" || fail "zsh -n $f"
done
python3 -c 'compile(open("guest/vendor/omarchy-native-clipboard-bridge").read(), "agent", "exec")' 2>/dev/null && pass "vendored clipboard agent compiles (in memory, no bytecode written)" || fail "vendored clipboard agent compiles"
python3 -c 'compile(open("guest/vendor/omarchy-native-battery-bridge").read(), "agent", "exec")' 2>/dev/null && pass "vendored battery agent compiles (in memory, no bytecode written)" || fail "vendored battery agent compiles"
python3 -c 'import json; json.load(open("guest/files/firefox-policies.json"))' && pass "firefox policies.json parses" || fail "firefox policies.json parses"
# 0a. time zone receiver: only the plain name of a zone file the guest has gets
#     through; everything else a host could send is rejected (run in memory
#     against a throwaway zoneinfo, no bytecode written)
mkdir -p "$T/zi/America"; : > "$T/zi/America/New_York"; : > "$T/zi/UTC"
python3 - guest/files/kdevm-timezone "$T/zi" <<'PYZ' && pass "time zone receiver: 2 real zones accepted, 15 hostile or malformed messages rejected" || fail "time zone receiver validation"
import json, sys
ns = {"__name__": "kdevm_timezone"}
exec(compile(open(sys.argv[1]).read(), sys.argv[1], "exec"), ns)
zone_from, zi = ns["zone_from"], sys.argv[2]
msg = lambda zone, **more: json.dumps({"type": "timezone", "zone": zone, **more}).encode() + b"\n"
for good in ("America/New_York", "UTC"):
    assert zone_from(msg(good), zi) == good, good
bad = [msg("../../etc/passwd"), msg("America/../UTC"), msg("/etc/passwd"), msg("Mars/Olympus"),
       msg("America"), msg(""), msg(123), msg(None), msg("UTC; reboot"), msg("UTC\n"), msg("A" * 129),
       msg("UTC", extra=1), json.dumps({"type": "clipboard", "zone": "UTC"}).encode(), b"[]\n", b"\xff\xfe not json\n"]
for line in bad:
    try:
        zone_from(line, zi)
    except ValueError:
        continue
    sys.exit(f"accepted: {line!r}")
PYZ

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

# A bridge helper, as kdevm sees one: the runtime's helper binary running one
# bridge on this state's socket. FH is set to the pid.
mkdir -p "$T/fakert4/current/bin"; : > "$T/fakert4/current/bin/kdevm"
printf '#!/bin/sh\ntrap '"'"'kill $c 2>/dev/null; exit 0'"'"' TERM\nsleep 120 & c=$!\nwait\n' > "$T/fakert4/current/bin/omarchy-vm-helper"; chmod +x "$T/fakert4/current/bin/"*
fake_helper() { # state dir, bridge
  "$T/fakert4/current/bin/omarchy-vm-helper" --bridge-native-$2 1 "$1/run/$2.sock" & FH=$!; sleep 0.3
}
k4() { local st=$1; shift; KDEVM_STATE="$st" KDEVM_RUNTIME_ROOT="$T/fakert4" ./kdevm.sh "$@"; } # state dir, verb...

# 4. stale pid files are not trusted (finding 4): a sleeper must survive down/status
mkdir -p "$T/v4"; sleep 120 & SL=$!
echo $SL > "$T/v4/qemu.pid"; echo $SL > "$T/v4/bridge-clipboard.pid"
k4 "$T/v4" down >/dev/null 2>&1
k4 "$T/v4" status >/dev/null 2>&1
if kill -0 $SL 2>/dev/null; then pass "stale pid: unrelated process left alive"; else fail "stale pid: unrelated process was signalled"; fi
[[ ! -e "$T/v4/qemu.pid" ]] && pass "stale qemu.pid removed" || fail "stale qemu.pid kept"
kill $SL 2>/dev/null; wait $SL 2>/dev/null
# 4b. a bridge record whose pid now belongs to something else (a reused pid,
#     an editor that mentions the helper) is never signalled, for any bridge
mkdir -p "$T/v4b"; ARGV0="vim /review/omarchy-vm-helper --bridge-native-clipboard notes" zsh -c 'sleep 120; :' & ED=$!; sleep 0.3
for b in clipboard battery timezone; do echo "$ED $(proc_start $ED)" > "$T/v4b/bridge-$b.pid"; done
k4 "$T/v4b" down >/dev/null 2>&1
if kill -0 $ED 2>/dev/null && [[ -z "$(ls "$T/v4b" | grep '^bridge-')" ]]; then pass "bridge records pointing at an unrelated process: process left alive, records dropped"; else fail "bridge record with a foreign pid (alive=$(kill -0 $ED 2>/dev/null && echo yes || echo no), records: $(ls "$T/v4b" | tr '\n' ' '))"; fi
kill $ED 2>/dev/null; wait $ED 2>/dev/null
# 4c. a real helper identity IS accepted (command line and start time) and stopped
mkdir -p "$T/v4c"; fake_helper "$T/v4c" battery; SV=$FH
echo "$SV $(proc_start $SV)" > "$T/v4c/bridge-battery.pid"
k4 "$T/v4c" down >/dev/null 2>&1
if kill -0 $SV 2>/dev/null || [[ -e "$T/v4c/bridge-battery.pid" ]]; then fail "bridge helper: a genuine helper was not stopped"; else pass "bridge helper: genuine identity accepted, stopped, record removed"; fi
kill $SV 2>/dev/null; wait $SV 2>/dev/null
#     ... but not under another bridge's record: the command line must be that bridge's
fake_helper "$T/v4c" battery; SV=$FH; echo "$SV $(proc_start $SV)" > "$T/v4c/bridge-clipboard.pid"
k4 "$T/v4c" down >/dev/null 2>&1
if kill -0 $SV 2>/dev/null && [[ ! -e "$T/v4c/bridge-clipboard.pid" ]]; then pass "bridge helper: a battery helper under the clipboard record is not signalled"; else fail "bridge record matched the wrong bridge's helper"; fi
kill $SV 2>/dev/null; wait $SV 2>/dev/null


# 4d. a record without a start time is never ours: sleeper survives, record dropped
mkdir -p "$T/v4d"; sleep 120 & SL2=$!; echo "$SL2" > "$T/v4d/qemu.pid"
KDEVM_STATE="$T/v4d" ./kdevm.sh down >/dev/null 2>&1
kill -0 $SL2 2>/dev/null && pass "pid record without start time: process left alive" || fail "pid record without start time: signalled"
[[ ! -e "$T/v4d/qemu.pid" ]] && pass "pid record without start time discarded" || fail "pid record without start time kept"
kill $SL2 2>/dev/null; wait $SL2 2>/dev/null
# 4e. inspection failure (ps broken) keeps the record, refuses the verb, signals nothing
mkdir -p "$T/v4e" "$T/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/ps"; chmod +x "$T/fakebin/ps"
sleep 120 & SL3=$!; echo "$SL3 $(proc_start $SL3)" > "$T/v4e/qemu.pid"
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
sleep 120 & SL4=$!; echo "$SL4 $(proc_start $SL4)" > "$T/v4f/qemu.pid"
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

# 4i. process identity does not depend on the caller's time zone: a record
#     written in one zone is recognised from another (the Mac changes zone
#     while the VM runs)
sleep 120 & SL5=$!
rec=$(TZ=Asia/Tokyo zsh -c "source $REPO/lib/kdevm-common.zsh; proc_start $SL5")
st=$(TZ=America/New_York zsh -c "source $REPO/lib/kdevm-common.zsh; pid_state $SL5 '$rec' 'sleep*'")
[[ -n "$rec" && "$st" == running ]] && pass "pid_state: a start time recorded in one time zone is recognised in another" || fail "process identity across time zones (record '$rec' gave '$st')"
kill $SL5 2>/dev/null; wait $SL5 2>/dev/null

# 4g. a bridge helper whose start time cannot be inspected during down:
#     not signalled, record kept, reported (down exits 2), not converted to absent
mkdir -p "$T/v4g"; fake_helper "$T/v4g" clipboard; SV2=$FH
echo "$SV2 $(proc_start $SV2)" > "$T/v4g/bridge-clipboard.pid"
cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done
exec /bin/ps "$@"
EOF
out=$(PATH="$T/fakebin2:$PATH" k4 "$T/v4g" down 2>&1); rc=$?
if kill -0 $SV2 2>/dev/null && [[ -f "$T/v4g/bridge-clipboard.pid" && $rc -eq 2 && "$out" == *"could not be verified"* && "$out" == *"tracking preserved"* ]]; then pass "helper unknown during down: not signalled, record kept, reported"; else fail "helper unknown during down (rc=$rc alive=$(kill -0 $SV2 2>/dev/null && echo yes || echo no) record=$([[ -f "$T/v4g/bridge-clipboard.pid" ]] && echo kept || echo removed))"; fi
out=$(k4 "$T/v4g" down 2>&1); rc=$?
if ! kill -0 $SV2 2>/dev/null && [[ ! -f "$T/v4g/bridge-clipboard.pid" && $rc -eq 0 ]]; then pass "same helper with inspection working again: stopped, exit confirmed, record removed"; else fail "helper stop after recovery (rc=$rc)"; kill $SV2 2>/dev/null; fi

# 4j. a helper that does not end on SIGTERM (stopped, so the signal stays
#     pending) keeps its record: down reports it and exits 2, and up refuses
#     to start over it. Once it can run again, down confirms its exit.
mkdir -p "$T/v4j"; fake_helper "$T/v4j" timezone; SV4=$FH
echo "$SV4 $(proc_start $SV4)" > "$T/v4j/bridge-timezone.pid"; kill -STOP $SV4
out=$(k4 "$T/v4j" down 2>&1); rc=$?
if kill -0 $SV4 2>/dev/null && [[ -f "$T/v4j/bridge-timezone.pid" && $rc -eq 2 && "$out" == *"did not exit after SIGTERM; tracking preserved"* ]]; then pass "helper that will not end: record kept, down exits 2 and says so"; else fail "unstoppable helper during down (rc=$rc: $out)"; fi
kill -CONT $SV4; sleep 0.5
out=$(k4 "$T/v4j" down 2>&1); rc=$?
if ! kill -0 $SV4 2>/dev/null && [[ ! -f "$T/v4j/bridge-timezone.pid" && $rc -eq 0 ]]; then pass "the same helper once it can run: exit confirmed, record removed"; else fail "helper after SIGCONT (rc=$rc)"; kill -9 $SV4 2>/dev/null; fi

# 4h. status reports an UNKNOWN bridge helper (record kept) in all three QEMU states.
#     A ps wrapper fails the start-time lookup only for the pid in KDEVM_TEST_UNKNOWN_PID.
cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
hit=0; for a in "$@"; do [ "$a" = "lstart=" ] && hit=1; done
if [ "$hit" = 1 ] && [ -n "$KDEVM_TEST_UNKNOWN_PID" ]; then for a in "$@"; do [ "$a" = "$KDEVM_TEST_UNKNOWN_PID" ] && exit 1; done; fi
exec /bin/ps "$@"
EOF
mkdir -p "$T/v4h"
# Network isolation for this fixture: status probes the ssh port with `nc`
# and, if it answers, runs diagnostics over `ssh`. Both are called by bare
# name, so stubs first in PATH intercept every call; the stubs log and fail
# (port "not answering", ssh exit 255), and nothing can reach a real service.
mkdir -p "$T/netstub"
printf '#!/bin/sh\necho "nc $*" >> "$KDEVM_TEST_NETLOG"; exit 1\n' > "$T/netstub/nc"
printf '#!/bin/sh\necho "ssh $*" >> "$KDEVM_TEST_NETLOG"; exit 255\n' > "$T/netstub/ssh"
chmod +x "$T/netstub/nc" "$T/netstub/ssh"; export KDEVM_TEST_NETLOG="$T/v4h/netlog"; : > "$KDEVM_TEST_NETLOG"
fake_helper "$T/v4h" clipboard; SV3=$FH
echo "$SV3 $(proc_start $SV3)" > "$T/v4h/bridge-clipboard.pid"
st_ok=1
check_status() { # label, expected qemu line fragment
  local out; out=$(PATH="$T/netstub:$T/fakebin2:$PATH" KDEVM_TEST_UNKNOWN_PID="${3:-$SV3}" KDEVM_STATE="$T/v4h" KDEVM_RUNTIME_ROOT="$T/fakert4" ./kdevm.sh status 2>&1)
  if [[ "$out" == *"bridge clipboard: UNKNOWN: pid $SV3 "* && "$out" == *"$2"* && -f "$T/v4h/bridge-clipboard.pid" ]] && kill -0 $SV3 2>/dev/null; then pass "status: helper UNKNOWN reported and record kept with QEMU $1"; else st_ok=0; fail "status with QEMU $1: $(echo "$out" | grep -E 'qemu:|bridge' | tr '\n' ' ')"; fi
}
# (a) QEMU absent: no qemu.pid
check_status absent "qemu: not running"
# (b) QEMU running: a process whose command line matches the runtime QEMU on this state's overlay
ARGV0="$T/fakert4/current/bin/kdevm -drive file=$T/v4h/work.qcow2" zsh -c 'sleep 120; :' & FQ=$!; sleep 0.3
echo "$FQ $(proc_start $FQ)" > "$T/v4h/qemu.pid"
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
  ok=1
  for pw in '&secret' '|secret' 'abc #secret' '12345678' 'q"uo\te' "it's" '{a: b}' '- dash' 'tab	here' ' leading space' 'üñî©ødé' '\\backslash' 'a\nb' 'pass🔑word'; do
    KDEVM_USER_NAME=tester KDEVM_PASS="$pw" KDEVM_SSHKEY='ssh-ed25519 AAAATEST comment #with: odd & chars' \
      python3 "$T/render.py" guest/user-data.yaml.tmpl "$T/ud.yaml" guest || { ok=0; continue; }
    KDEVM_PASS="$pw" .venv/bin/python -c 'import yaml,os,sys; d=yaml.safe_load(open(sys.argv[1])); u=d["users"][0]; sys.exit(0 if u["plain_text_passwd"]==os.environ["KDEVM_PASS"] and u["ssh_authorized_keys"][0]=="ssh-ed25519 AAAATEST comment #with: odd & chars" else 1)' "$T/ud.yaml" || { ok=0; echo "      password case failed: ${(q)pw}"; }
  done
  [[ $ok -eq 1 ]] && pass "14 hostile passwords (incl. non-BMP) and a hostile key round-trip through YAML" || fail "YAML rendering"
  # 7a. time zone: the rendered seed installs the receiver byte for byte, its
  #     unit and the udev rule that starts it, and the port name is the same
  #     in the launcher, the receiver and the rule
  .venv/bin/python - "$T/ud.yaml" <<'PYT' && pass "time zone: receiver, unit and udev rule rendered; one port name in launcher, receiver and rule" || fail "time zone pieces in the rendered user-data"
import base64, sys, yaml
files = {f["path"]: f for f in yaml.safe_load(open(sys.argv[1]))["write_files"]}
agent, port = files["/usr/local/sbin/kdevm-timezone"], "dev.tryomarchy.timezone"
source = open("guest/files/kdevm-timezone", "rb").read()
assert base64.b64decode(agent["content"]) == source and agent["permissions"] == "0755"
assert "ExecStart=/usr/local/sbin/kdevm-timezone" in files["/etc/systemd/system/kdevm-timezone.service"]["content"]
rule = files["/etc/udev/rules.d/93-kdevm-timezone.rules"]["content"]
assert f'ATTR{{name}}=="{port}"' in rule and 'ENV{SYSTEMD_WANTS}+="kdevm-timezone.service"' in rule
assert f"name={port}" in open("kdevm.sh").read() and f'"/dev/virtio-ports/{port}"'.encode() in source
PYT
  # 7b. battery: every vendored file reaches the seed byte for byte at the
  #     path the guest expects, the DKMS version in the path is the one in
  #     dkms.conf, and the port name is the same in launcher, agent and rule
  .venv/bin/python - "$T/ud.yaml" <<'PYB' && pass "battery: vendored files rendered byte for byte; DKMS version and port name consistent; UPower critical action turned off and checked by the factory" || fail "battery pieces in the rendered user-data"
import base64, re, sys, yaml
seed = yaml.safe_load(open(sys.argv[1])); files = {f["path"]: f for f in seed["write_files"]}
V = "guest/vendor/"; version = re.search(r'PACKAGE_VERSION="([^"]+)"', open(V + "try-omarchy-battery/dkms.conf").read()).group(1)
src = f"/usr/src/try-omarchy-battery-{version}/"
for path, vendored in {
    src + "try-omarchy-battery.c": "try-omarchy-battery/try-omarchy-battery.c", src + "Makefile": "try-omarchy-battery/Makefile",
    src + "dkms.conf": "try-omarchy-battery/dkms.conf", "/etc/modules-load.d/95-try-omarchy-battery.conf": "95-try-omarchy-battery.conf",
    "/usr/local/bin/omarchy-native-battery-bridge": "omarchy-native-battery-bridge",
    "/etc/systemd/system/omarchy-native-battery-bridge.service": "omarchy-native-battery-bridge.service",
    "/etc/udev/rules.d/95-omarchy-native-battery.rules": "95-omarchy-native-battery.rules",
}.items():
    assert base64.b64decode(files[path]["content"]) == open(V + vendored, "rb").read(), path
assert files["/usr/local/bin/omarchy-native-battery-bridge"]["permissions"] == "0755"
run = [" ".join(c) if isinstance(c, list) else c for c in seed["runcmd"]]
assert any(f"dkms install try-omarchy-battery/{version} " in c for c in run) and "systemctl enable omarchy-native-battery-bridge.service" in run
assert {"dkms", "linux-headers-arm64", "powerdevil"} <= set(seed["packages"])
# nothing acts on the mirrored battery: UPower's own critical action is turned off, and the factory build checks it took
assert any("s/^CriticalPowerAction=.*/CriticalPowerAction=Ignore/" in c and "/etc/UPower/UPower.conf" in c for c in run)
assert "grep -qx 'CriticalPowerAction=Ignore' /etc/UPower/UPower.conf" in open("guest/factory.zsh").read()
port = "dev.tryomarchy.battery"
assert f"name={port}" in open("kdevm.sh").read() and port in open(V + "omarchy-native-battery-bridge").read() and port in open(V + "95-omarchy-native-battery.rules").read()
PYB
else
  echo "SKIP  YAML rendering and the rendered-seed checks (no .venv with PyYAML; see header)"
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
  cat > "$FRT/bin/kdevm" <<'EOF'
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
  chmod +x "$FRT/bin/kdevm"
  printf '#!/bin/sh\necho 48000\n' > "$FRT/bin/omarchy-vm-helper"; chmod +x "$FRT/bin/omarchy-vm-helper"
  "$QI" create -q -f qcow2 "$T/v10/factory.qcow2" 1M
  : > "$T/v10/code.fd"; : > "$T/v10/vars.fd"
  out=$(KDEVM_STATE="$T/v10" KDEVM_RUNTIME_ROOT="$T/fakert" KDEVM_FW_CODE="$T/v10/code.fd" KDEVM_FW_VARS="$T/v10/vars.fd" KDEVM_SHARE="$T/v10/share" KDEVM_WINDOW=keep KDEVM_ICON= ./kdevm.sh up 2>&1); rc=$?
  left=$(pgrep -f "$FRT/bin/kdevm" || true)
  if [[ $rc -ne 0 && -z "$left" && ! -e "$T/v10/qemu.pid" && "$out" == *"failed to start"* ]]; then pass "failed readiness: fake QEMU terminated, non-zero exit, no pid file"; else fail "failed readiness (rc=$rc, leftover='$left')"; [[ -n "$left" ]] && kill $left 2>/dev/null; fi
  # 10a. Dock icon: the same up built TryOmarchy.icns in the runtime root (where
  #      the patched QEMU looks) from the repo's PNG and left no work files
  ICNS="$T/fakert/TryOmarchy.icns"
  if [[ "$(head -c 4 "$ICNS" 2>/dev/null)" == icns && -z "$(ls "$T/fakert" | grep -v -x -e current -e TryOmarchy.icns)" && ! -e "$T/v10/icon.iconset" && "$out" != *"Dock icon"* ]]; then pass "Dock icon: icns built in the runtime root from the default PNG, no work files left"; else fail "Dock icon install ($(ls "$T/fakert" | tr '\n' ' '))"; fi
  # 10b. start-time capture fails right after launch: the child is terminated, not orphaned
  rm -rf "$T/v10/run" "$T/v10/work.qcow2" "$T/v10/vars.fd"; : > "$T/v10/vars.fd"
  cat > "$T/fakebin2/ps" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done
exec /bin/ps "$@"
EOF
  out=$(PATH="$T/fakebin2:$PATH" KDEVM_STATE="$T/v10" KDEVM_RUNTIME_ROOT="$T/fakert" KDEVM_FW_CODE="$T/v10/code.fd" KDEVM_FW_VARS="$T/v10/vars.fd" KDEVM_SHARE="$T/v10/share" KDEVM_WINDOW=keep ./kdevm.sh up 2>&1); rc=$?
  left=$(pgrep -f "$FRT/bin/kdevm" || true)
  if [[ $rc -ne 0 && -z "$left" && ! -e "$T/v10/qemu.pid" && "$out" == *"start time"* ]]; then pass "launch-time start capture failure: child terminated, no pid file"; else fail "start capture failure (rc=$rc, leftover='$left')"; [[ -n "$left" ]] && kill $left 2>/dev/null; fi
  # 10c. an unusable KDEVM_ICON is a warning, not a stop: up goes on to launch
  #      QEMU (it reaches the start-time failure above) and the icns in place
  #      is untouched
  rm -rf "$T/v10/run" "$T/v10/work.qcow2" "$T/v10/vars.fd"; : > "$T/v10/vars.fd"
  printf 'not an image' > "$T/v10/bad.png"; before=$(shasum "$ICNS" 2>/dev/null)
  out=$(PATH="$T/fakebin2:$PATH" KDEVM_STATE="$T/v10" KDEVM_RUNTIME_ROOT="$T/fakert" KDEVM_FW_CODE="$T/v10/code.fd" KDEVM_FW_VARS="$T/v10/vars.fd" KDEVM_SHARE="$T/v10/share" KDEVM_WINDOW=keep KDEVM_ICON="$T/v10/bad.png" ./kdevm.sh up 2>&1); rc=$?
  left=$(pgrep -f "$FRT/bin/kdevm" || true)
  if [[ "$out" == *"could not build the Dock icon"* && "$out" == *"start time"* && -n "$before" && "$(shasum "$ICNS")" == "$before" && -z "$(ls "$T/fakert" | grep -v -x -e current -e TryOmarchy.icns)" && ! -e "$T/v10/icon.iconset" ]]; then pass "Dock icon: unusable KDEVM_ICON warns, up continues, existing icns untouched"; else fail "Dock icon failure handling (rc=$rc)"; fi
  [[ -n "$left" ]] && kill $left 2>/dev/null
else
  echo "SKIP  failed-readiness probe (no qemu-img)"
fi


# 11. wrapper-driven factory execution: kdevm.sh factory runs the build in ITS
#     OWN process while holding the lock (no delegated builder). A fake QEMU
#     records its parent pid and whether the state lock is held, then exits.
QI="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
if [[ -x "$QI" ]] && command -v mkisofs >/dev/null; then
  F2="$T/fakert2/current/bin"; mkdir -p "$F2" "$T/v11"
  cat > "$F2/kdevm" <<'EOF'
#!/bin/zsh
# fake provisioning QEMU: who launched me, is the lock held, then fail fast
echo $PPID > "$KDEVM_STATE/fakeqemu.ppid"
zmodload zsh/system
if zsystem flock -t 0 "$KDEVM_STATE/lock" 2>/dev/null; then echo free; else echo held; fi > "$KDEVM_STATE/fakeqemu.lock"
[[ -n "${KDEVM_FAKE_QEMU_SLEEP:-}" ]] && sleep "$KDEVM_FAKE_QEMU_SLEEP"
exit 1
EOF
  chmod +x "$F2/kdevm"
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
  F3="$T/fakert3/current/bin"; mkdir -p "$F3" "$T/v11b"; cp "$F2/kdevm" "$F3/"
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
  orphan=$(pgrep -f "$F2/kdevm" || true)
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

# 12b. two runtime builds cannot share a scratch checkout or a runtime root:
#      a builder that finds either kernel lock held refuses before touching
#      the checkout (a concurrent build would revert its rebrand edits)
for held in root scratch; do
  mkdir -p "$T/v12b/$held/rt" "$T/v12b/$held/scratch"
  [[ $held == root ]] && lf="$T/v12b/$held/rt/build.lock" || lf="$T/v12b/$held/scratch/build.lock"
  zsh -c 'zmodload zsh/system; : >> "$1"; zsystem flock "$1"; echo held; sleep 30' _ "$lf" > "$T/v12b/$held/holder.out" 2>&1 & LH3=$!
  for i in {1..50}; do [[ "$(cat "$T/v12b/$held/holder.out" 2>/dev/null)" == held ]] && break; sleep 0.1; done
  out=$(KDEVM_RUNTIME_ROOT="$T/v12b/$held/rt" KDEVM_SCRATCH="$T/v12b/$held/scratch" ./runtime/build.sh 2>&1); rc=$?
  if [[ $rc -ne 0 && "$out" == *"another runtime build is running"* && "$out" != *"KDEVM_OFFLINE"* && ! -d "$T/v12b/$held/scratch/try-omarchy" ]]; then pass "runtime build refused while another holds the $held lock; checkout untouched"; else fail "runtime build lock ($held; rc=$rc: $out)"; fi
  kill $LH3 2>/dev/null; wait $LH3 2>/dev/null
done

# 12c. a QEMU that has this state's overlay open but is not vouched for by the
#      pid record (no record, or one written by an older kdevm: another start
#      time rendering) is never treated as stopped: down, destroy and rebuild
#      refuse, the disks stay, the process is not signalled
mkdir -p "$T/v12c"; : > "$T/v12c/work.qcow2"; : > "$T/v12c/efivars.fd"; : > "$T/v12c/factory.qcow2"
ARGV0="/old/runtime/bin/qemu-system-aarch64 -name kdevm -drive if=none,id=root,file=$T/v12c/work.qcow2,format=qcow2" zsh -c 'sleep 120; :' & OLDQ=$!; sleep 0.3
stray_ok=1
for record in none old; do
  for verb in down destroy "destroy --all" rebuild; do
    [[ $record == old ]] && echo "$OLDQ $(TZ=Asia/Tokyo ps -o lstart= -p $OLDQ | awk '{$1=$1; print}')" > "$T/v12c/qemu.pid" || rm -f "$T/v12c/qemu.pid"
    out=$(KDEVM_STATE="$T/v12c" KDEVM_RUNTIME_ROOT="$T/fakert4" ./kdevm.sh ${=verb} 2>&1); rc=$?
    if [[ $rc -eq 0 || "$out" != *"but is not tracked"* || "$out" != *"pid $OLDQ"* || ! -e "$T/v12c/work.qcow2" || ! -e "$T/v12c/efivars.fd" || ! -e "$T/v12c/factory.qcow2" ]] || ! kill -0 $OLDQ 2>/dev/null; then stray_ok=0; echo "      $verb with record=$record: rc=$rc $(echo "$out" | tail -1)"; fi
  done
done
[[ $stray_ok -eq 1 ]] && pass "untracked QEMU on the overlay: down, destroy, destroy --all and rebuild refuse (no record, and a 0.1-style record); disks kept, process untouched" || fail "stray QEMU guard on destructive verbs"
kill $OLDQ 2>/dev/null; wait $OLDQ 2>/dev/null
# the same verbs still work when nothing has the overlay open
out=$(KDEVM_STATE="$T/v12c" KDEVM_RUNTIME_ROOT="$T/fakert4" ./kdevm.sh destroy 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$T/v12c/work.qcow2" && -e "$T/v12c/factory.qcow2" ]] && pass "destroy with nothing on the overlay: overlay removed, factory kept" || fail "destroy on an idle state (rc=$rc: $out)"

# 13. host bridges, end to end with fakes: a fake QEMU that binds every chardev
#     socket and answers QMP (system_powerdown ends it), and a fake helper that
#     logs each bridge it is asked to run. ssh and nc are the failing stubs of
#     4h, so down goes through QMP and nothing leaves the fixture.
QI="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
if [[ -x "$QI" ]]; then
  F5="$T/fakert5/current/bin"; mkdir -p "$F5" "$T/v13"
  cat > "$F5/kdevm" <<'EOF'
#!/usr/bin/env python3
import json, os, socket, sys
args = sys.argv[1:]
open(os.environ["KDEVM_STATE"] + "/fakeqemu.argv", "w").write("\n".join(args) + "\n")
qmp = [a for a in args if a.startswith("unix:")][0][5:].split(",")[0]
keep = []
for a in args:
    if a.startswith("socket,id="):
        s = socket.socket(socket.AF_UNIX); s.bind(a.split("path=")[1].split(",")[0]); s.listen(4); keep.append(s)
srv = socket.socket(socket.AF_UNIX); srv.bind(qmp); srv.listen(4)
while True:
    c, _ = srv.accept(); f = c.makefile("rw")
    f.write(json.dumps({"QMP": {"version": {}, "capabilities": []}}) + "\n"); f.flush()
    f.readline(); f.write(json.dumps({"return": {}}) + "\n"); f.flush()
    line = f.readline()
    cmd = json.loads(line)["execute"] if line else ""
    f.write(json.dumps({"return": {"status": "running", "running": True} if cmd == "query-status" else {}}) + "\n"); f.flush()
    c.close()
    if cmd == "system_powerdown": sys.exit(0)
EOF
  cat > "$F5/omarchy-vm-helper" <<'EOF'
#!/bin/sh
case "$1" in
  --host-audio-frequency) echo 48000 ;;
  --bridge-native-*) [ "--bridge-native-$KDEVM_FAKE_HELPER_FAIL" = "$1" ] && exit 1
     echo "$1 $2 $3 $$" >> "$KDEVM_STATE/helpers.log"; trap 'kill $c 2>/dev/null; exit 0' TERM; sleep 300 & c=$!; wait ;;
esac
EOF
  chmod +x "$F5/kdevm" "$F5/omarchy-vm-helper"
  "$QI" create -q -f qcow2 "$T/v13/factory.qcow2" 1M
  : > "$T/v13/code.fd"; : > "$T/v13/vars.fd"; export KDEVM_TEST_NETLOG="$T/v13/netlog"; : > "$KDEVM_TEST_NETLOG"
  k13() { PATH="$T/netstub:$PATH" KDEVM_STATE="$T/v13" KDEVM_RUNTIME_ROOT="$T/fakert5" KDEVM_FW_CODE="$T/v13/code.fd" KDEVM_FW_VARS="$T/v13/vars.fd" KDEVM_SHARE="$T/v13/share" KDEVM_WINDOW=keep ./kdevm.sh "$@" 2>&1; }
  helpers13() { pgrep -f "$F5/omarchy-vm-helper --bridge-native" | tr '\n' ' '; }
  logged13() { grep -c -- "^--bridge-native-$1 $FQ13 $T/v13/run/$1.sock " "$T/v13/helpers.log" 2>/dev/null; } # bridge -> starts on its socket for this QEMU
  rec13() { cut -d' ' -f1 "$T/v13/bridge-$1.pid" 2>/dev/null; } # bridge -> recorded helper pid
  # 13a. default (mirror): the ports are on the command line and each helper runs on its own socket
  out=$(k13 up); rc=$?; FQ13=$(cut -d' ' -f1 "$T/v13/qemu.pid" 2>/dev/null); sleep 1.5
  argv=$(cat "$T/v13/fakeqemu.argv" 2>/dev/null)
  if [[ $rc -eq 0 && "$argv" == *"socket,id=tz,path=$T/v13/run/timezone.sock,server=on,wait=off"* && "$argv" == *"chardev=tz,name=dev.tryomarchy.timezone"* && "$argv" == *"socket,id=bat,path=$T/v13/run/battery.sock,server=on,wait=off"* && "$argv" == *"chardev=bat,name=dev.tryomarchy.battery"* && "$(logged13 clipboard)" == 1 && "$(logged13 timezone)" == 1 && "$(logged13 battery)" == 1 ]]; then pass "up: time zone and battery ports on the QEMU command line; one helper per bridge started on its own socket"; else fail "up with time zone mirroring (rc=$rc: $(echo "$out" | tail -2 | tr '\n' ' ') log: $(tr '\n' ';' < "$T/v13/helpers.log" 2>/dev/null))"; fi
  out=$(k13 status); c13=$(rec13 clipboard); b13=$(rec13 battery); t13=$(rec13 timezone)
  if [[ -n "$c13" && -n "$b13" && -n "$t13" && "$out" == *"-- bridge clipboard: helper pid $c13"* && "$out" == *"-- bridge battery: helper pid $b13"* && "$out" == *"-- bridge timezone: helper pid $t13"* && "$(echo $(helpers13) | wc -w | tr -d ' ')" == 3 ]]; then pass "status: each of the three helpers reported by its recorded pid; no other process involved"; else fail "status bridge lines: $(echo "$out" | grep bridge | tr '\n' ';')"; fi
  # 13b. nothing restarts a helper: one that dies is reported NOT RUNNING, the others are untouched
  kill $t13 2>/dev/null; sleep 1.5; out=$(k13 status)
  if ! kill -0 $t13 2>/dev/null && [[ "$out" == *"-- bridge timezone: NOT RUNNING"* && "$out" == *"-- bridge clipboard: helper pid $c13"* && "$out" == *"-- bridge battery: helper pid $b13"* && "$(logged13 timezone)" == 1 && -f "$T/v13/bridge-timezone.pid" ]]; then pass "a helper that dies is not restarted: status says NOT RUNNING, the other helpers are untouched, status changed nothing"; else fail "dead helper reporting: $(echo "$out" | grep bridge | tr '\n' ';')"; fi
  # 13c. down (ssh stubbed out, so QMP): QEMU and every helper gone; records and sockets removed
  out=$(k13 down); rc=$?; sleep 0.5
  if [[ $rc -eq 0 && -z "$(helpers13)" && ! -e "$T/v13/qemu.pid" && -z "$(ls "$T/v13" | grep '^bridge-.*pid')" && ! -e "$T/v13/run/timezone.sock" && ! -e "$T/v13/run/clipboard.sock" && ! -e "$T/v13/run/battery.sock" ]] && ! kill -0 "$FQ13" 2>/dev/null; then pass "down: QEMU and all helpers gone; pid records and sockets removed"; else fail "down after bridges (rc=$rc helpers='$(helpers13)': $(echo "$out" | tail -2 | tr '\n' ' '))"; fi
  # 13d. KDEVM_TIMEZONE=off: no port, no time zone helper, status says so
  : > "$T/v13/helpers.log"
  out=$(KDEVM_TIMEZONE=off k13 up); rc=$?; FQ13=$(cut -d' ' -f1 "$T/v13/qemu.pid" 2>/dev/null); sleep 1.5
  argv=$(cat "$T/v13/fakeqemu.argv" 2>/dev/null); st=$(KDEVM_TIMEZONE=off k13 status)
  if [[ $rc -eq 0 && "$argv" != *timezone* && "$(logged13 clipboard)" == 1 && "$(logged13 battery)" == 1 && "$(grep -c timezone "$T/v13/helpers.log")" == 0 && ! -e "$T/v13/run/timezone.sock" && "$st" == *"-- bridge timezone: off"* && ! -e "$T/v13/bridge-timezone.pid" ]]; then pass "KDEVM_TIMEZONE=off: no port, no time zone helper or record, status says off"; else fail "KDEVM_TIMEZONE=off (rc=$rc argv has timezone: $([[ "$argv" == *timezone* ]] && echo yes || echo no), log: $(tr '\n' ';' < "$T/v13/helpers.log"))"; fi
  # 13e. the VM ends without down (the guest powers itself off): helpers that
  #      outlive it are stopped by the next up, by verified identity, before
  #      new ones are recorded; then down is clean
  c13=$(rec13 clipboard); b13=$(rec13 battery); kill "$FQ13" 2>/dev/null; sleep 0.5
  out=$(k13 up); rc=$?; FQ13=$(cut -d' ' -f1 "$T/v13/qemu.pid" 2>/dev/null); sleep 1
  if [[ $rc -eq 0 && -n "$c13" && -n "$b13" && "$(rec13 clipboard)" != "$c13" && "$(rec13 battery)" != "$b13" && -n "$(rec13 timezone)" && "$(echo $(helpers13) | wc -w | tr -d ' ')" == 3 ]] && ! kill -0 $c13 2>/dev/null && ! kill -0 $b13 2>/dev/null; then pass "up after the VM ended by itself: the two leftover helpers stopped, three new ones recorded"; else fail "up over leftover helpers (rc=$rc helpers='$(helpers13)': $(echo "$out" | tail -2 | tr '\n' ' '))"; fi
  out=$(k13 down); rc=$?
  [[ $rc -eq 0 && -z "$(helpers13)" ]] && ! kill -0 "$FQ13" 2>/dev/null && pass "down afterwards: clean exit, no helper left" || fail "down after restart (rc=$rc helpers='$(helpers13)')"
  # 13g. a helper that exits at once does not stop the desktop: up succeeds, status reports that bridge NOT RUNNING
  out=$(KDEVM_FAKE_HELPER_FAIL=battery k13 up); rc=$?; sleep 1; st=$(k13 status)
  if [[ $rc -eq 0 && "$st" == *"-- bridge battery: NOT RUNNING"* && "$st" == *"-- bridge clipboard: helper pid "* && "$st" == *"-- bridge timezone: helper pid "* ]]; then pass "a helper that exits at once: up still succeeds, status reports that bridge NOT RUNNING"; else fail "helper failing at start (rc=$rc: $(echo "$st" | grep bridge | tr '\n' ';'))"; fi
  out=$(k13 down); rc=$?; [[ $rc -eq 0 && -z "$(helpers13)" ]] || fail "down after a failed helper (rc=$rc)"
  # 13f. any other value is refused before anything starts
  rm -f "$T/v13/fakeqemu.argv"
  out=$(KDEVM_TIMEZONE=utc k13 up); rc=$?
  [[ $rc -ne 0 && "$out" == *"KDEVM_TIMEZONE must be mirror or off"* && ! -e "$T/v13/fakeqemu.argv" && ! -e "$T/v13/qemu.pid" ]] && pass "KDEVM_TIMEZONE with another value: refused, nothing launched" || fail "KDEVM_TIMEZONE validation (rc=$rc)"
  #      ... and before anything is built: with no runtime and no factory at
  #      all, the refusal is still about the value, not a build attempt
  mkdir -p "$T/v13f"
  out=$(KDEVM_TIMEZONE=utc KDEVM_STATE="$T/v13f/state" KDEVM_RUNTIME_ROOT="$T/v13f/rt" ./kdevm.sh up 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"KDEVM_TIMEZONE must be mirror or off"* && "$out" != *building* && "$out" != *KDEVM_OFFLINE* && ! -e "$T/v13f/rt" && ! -e "$T/v13f/state/factory.qcow2.building" ]] && pass "KDEVM_TIMEZONE is validated before the runtime or factory would be built" || fail "KDEVM_TIMEZONE validated too late (rc=$rc: $out)"
  # isolation: every network call in this fixture went to a stub
  grep -q '^ssh ' "$KDEVM_TEST_NETLOG" && pass "bridge fixture: down's ssh went to the stub, no real service contacted" || fail "bridge fixture network isolation (log: $(tr '\n' ';' < "$KDEVM_TEST_NETLOG"))"
  unset KDEVM_TEST_NETLOG
  leftover=$(pgrep -f "$T/fakert5/" | tr '\n' ' '); [[ -n "$leftover" ]] && kill ${=leftover} 2>/dev/null
else
  echo "SKIP  host bridge probes (no qemu-img)"
fi

echo
[[ $fails -eq 0 ]] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
