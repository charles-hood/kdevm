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
# same config loader as the scripts: explicit environment wins over the file
kdevm_load_env() {
  local f="$HOME/.config/kdevm/env" line k v; [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ '^[[:space:]]*(export[[:space:]]+)?(KDEVM_[A-Z_]+)=(.*)$' ]] || continue
    k="${match[2]}"; v="${match[3]}"
    [[ -n "${(P)k:-}" ]] && continue
    eval "export $k=$v"
  done < "$f"
}
kdevm_load_env
T="$(mktemp -d "${TMPDIR:-/tmp}/kdevm-checks.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
need_runtime() { [[ -x "${KDEVM_RUNTIME_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/kdevm/runtime}/current/bin/qemu-system-aarch64" ]]; }

# 0. syntax
for f in kdevm.sh guest/build.sh runtime/build.sh tests/checks.sh; do
  zsh -n "$f" && pass "zsh -n $f" || fail "zsh -n $f"
done
python3 -m py_compile guest/vendor/omarchy-native-clipboard-bridge 2>/dev/null && pass "vendored clipboard agent compiles" || fail "vendored clipboard agent compiles"
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
  out=$(KDEVM_STATE="$T/v3" ./guest/build.sh --force 2>&1); rc=$?
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

# 5. lock (finding 5): live holder blocks, dead holder is reclaimed, lock released after
mkdir -p "$T/v5/lock"; sleep 120 & H=$!; echo $H > "$T/v5/lock/pid"
out=$(KDEVM_STATE="$T/v5" ./kdevm.sh down 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"another kdevm command"* ]] && pass "lock held by a live process blocks" || fail "lock held by a live process (rc=$rc)"
kill $H 2>/dev/null; wait $H 2>/dev/null
echo 999999 > "$T/v5/lock/pid"
KDEVM_STATE="$T/v5" ./kdevm.sh down >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && ! -d "$T/v5/lock" ]] && pass "dead lock holder reclaimed and lock released" || fail "dead lock reclaim (rc=$rc)"

# 6. private permissions (finding 6): the state dir a command creates is 0700
[[ "$(stat -f %Lp "$T/v5")" == 700 || "$(stat -f %Lp "$T/v4")" == 700 ]] && pass "state directory created 0700" || fail "state directory mode"

# 7. YAML rendering (finding 7): hostile passwords and keys survive the template
if [[ -x .venv/bin/python ]] && .venv/bin/python -c 'import yaml' 2>/dev/null; then
  awk "/<<'PY'\$/{f=1; next} f && /^PY\$/{exit} f" guest/build.sh > "$T/render.py"
  V=guest/vendor; ok=1
  for pw in '&secret' '|secret' 'abc #secret' '12345678' 'q"uo\te' "it's" '{a: b}' '- dash' 'tab	here' ' leading space' 'üñî©ødé' '\\backslash' 'a\nb'; do
    KDEVM_USER_NAME=tester KDEVM_PASS="$pw" KDEVM_SSHKEY='ssh-ed25519 AAAATEST comment #with: odd & chars' \
      python3 "$T/render.py" guest/user-data.yaml.tmpl "$T/ud.yaml" "$V/omarchy-native-clipboard-bridge" \
      "$V/omarchy-native-clipboard-bridge.service" "$V/92-omarchy-native-clipboard.rules" \
      "$V/90-try-omarchy-quantum.conf" guest/files/firefox-policies.json || { ok=0; continue; }
    KDEVM_PASS="$pw" .venv/bin/python -c 'import yaml,os,sys; d=yaml.safe_load(open(sys.argv[1])); u=d["users"][0]; sys.exit(0 if u["plain_text_passwd"]==os.environ["KDEVM_PASS"] and u["ssh_authorized_keys"][0]=="ssh-ed25519 AAAATEST comment #with: odd & chars" else 1)' "$T/ud.yaml" || { ok=0; echo "      password case failed: ${(q)pw}"; }
  done
  [[ $ok -eq 1 ]] && pass "13 hostile passwords and a hostile key round-trip through YAML" || fail "YAML rendering"
else
  echo "SKIP  YAML rendering (no .venv with PyYAML; see header)"
fi

echo
[[ $fails -eq 0 ]] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
