#!/usr/bin/env bash
# ============================================================================
# CMDR test suite — exhaustive, self-contained, runs against an isolated
# CMDR_DATA_DIR. Safe to run anywhere (CI or local). Requires: bash, jq.
# Optional (feature paths degrade gracefully if absent): age/gpg, fzf, ssh.
# ============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$ROOT/cmdr.sh"
PASS=0; FAIL=0; FAILED=()

td() { mktemp -d "${TMPDIR:-/tmp}/cmdrT.XXXXXX"; }
# Point CMDR at a fresh, isolated data dir for the next group of tests.
newdata() { CMDR_DATA_DIR="$(td)"; export CMDR_DATA_DIR; }
_strip() { sed $'s/\033\[[0-9;]*m//g'; }

# okc NAME EXPECTED_EXIT -- cmd...    (checks exit code)
okc() { local name="$1" exp="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$name (exit $rc != $exp)"); fi; }
# okg NAME REGEX -- cmd...            (ANSI-stripped output must match)
okg() { local name="$1" re="$2"; shift 2; local out; out=$("$@" 2>&1 | _strip)
  if printf '%s' "$out" | grep -qE -e "$re"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$name (no match /$re/)"); fi; }
# okng NAME REGEX -- cmd...           (output must NOT match)
okng() { local name="$1" re="$2"; shift 2; local out; out=$("$@" 2>&1 | _strip)
  if printf '%s' "$out" | grep -qE -e "$re"; then FAIL=$((FAIL+1)); FAILED+=("$name (unexpected /$re/)"); else PASS=$((PASS+1)); fi; }

section() { echo "── $* ────────────────────────────────"; }

section "SYNTAX"
for f in cmdr.sh cmdr_functions.sh cmdr_completion.bash install.sh; do
  okc "syntax:$f" 0 bash -n "$ROOT/$f"
done
okc "completion-sources" 0 bash -c "source '$ROOT/cmdr_completion.bash'"

section "CRUD + SEARCH + ALIASES"
newdata
okg  "add"            "added successfully"        "$C" -a serve 'echo serving {PORT}' dev --desc 'http' --alias s --alias srv
okc  "add-dup-fails"  1                           "$C" -a serve 'echo x' dev
okg  "show-has-tag"   "serve"                     "$C" -s
okg  "search-cmd"     "serve"                     "$C" -f serving
okg  "search-none"    "No commands matching"      "$C" -f zzzzz
okg  "alias-resolve"  "serving"                   "$C" -n -r srv
okg  "edit"           "updated successfully"      "$C" -e serve 'echo edited {PORT}'
okg  "edit-applied"   "edited"                    "$C" -n -r serve
okc  "edit-missing"   1                           "$C" -e ghost 'echo x'
okg  "delete-y"       "deleted successfully"      "$C" -d serve -y
okc  "delete-missing" 1                           "$C" -d ghost -y

section "SANITIZATION"
newdata
okc  "bad-tag"        1                           "$C" -a 'bad tag' 'echo x' dev
okc  "empty-tag"      1                           "$C" -a '' 'echo x' dev
okg  "param-exec-ok"  "added successfully"        "$C" -a tpl '{tool} -x {TARGET}' net

section "ENV + PLACEHOLDERS"
newdata
"$C" -a scan 'echo nmap {TARGET} -p {PORT:=80}' net >/dev/null 2>&1
"$C" -a req  'echo need {MUST:?}' net >/dev/null 2>&1
okg  "default-ph"     "nmap 1.1.1.1 -p 80"        "$C" -n -r scan 1.1.1.1
okg  "positional"     "nmap 1.1.1.1 -p 443"       "$C" -n -r scan 1.1.1.1 443
okg  "required-miss"  "Required value"            "$C" -n -r req
okg  "required-given" "need yes"                  "$C" -n -r req yes
okg  "env-set"        "Set:"                      "$C" --env TARGET=10.0.0.1
okg  "env-subst"      "nmap 10.0.0.1 -p 80"       "$C" -n -r scan
okg  "env-then-pos"   "nmap 10.0.0.1 -p 9000"     "$C" -n -r scan 9000
okg  "env-clear"      "Cleared:"                  "$C" --env-clear TARGET
okng "env-cleared"    "10.0.0.1"                  "$C" --env

section "HOSTS"
newdata
"$C" -a hs 'echo {TARGET} {OS} {RUSER} {RPORT}' net >/dev/null 2>&1
okg  "host-add"       "Host added"                "$C" --host add 10.10.10.5 --name dc01 --os windows --user admin --port 5985
"$C" --host add 10.10.10.6 --name web01 >/dev/null 2>&1
okg  "host-align"     "windows.*admin"            "$C" --host list
okg  "host-vars"      "10.10.10.5 windows admin 5985" "$C" -n -r hs @dc01
okg  "all-hosts-a"    "dc01"                      "$C" -n -r hs --all-hosts
okg  "all-hosts-b"    "web01"                     "$C" -n -r hs --all-hosts
okc  "unknown-host"   1                           "$C" -r hs @nope
okg  "host-rm"        "Host removed"              "$C" --host rm web01
okc  "host-bad-sub"   1                           "$C" --host frobnicate

section "OUTPUT CAPTURE"
newdata
"$C" -a gt 'echo token=ABC123' net >/dev/null 2>&1
"$C" -a ut 'echo using {SECRET}' net >/dev/null 2>&1
okg  "capture-regex"  "Captured \{SECRET\} = ABC123" "$C" -r gt --capture 'SECRET:ABC[0-9]+'
okg  "capture-used"   "using ABC123"              "$C" -n -r ut

section "REMOTE (dry-run)"
newdata
"$C" --host add 10.0.0.9 --name r1 --user root --port 2222 >/dev/null 2>&1
"$C" --host add 10.0.0.8 --name r2 >/dev/null 2>&1
"$C" -a who 'whoami' enum >/dev/null 2>&1
okg  "ssh-port"       "ssh -p 2222 root@10.0.0.9" "$C" -n -r who --on r1
okg  "ssh-noport"     "ssh 10.0.0.8"              "$C" -n -r who --on r2

section "DANGER"
newdata
"$C" -a wipe 'echo WIPE {D}' ops --danger >/dev/null 2>&1
okg  "danger-mark"    "\[!\]"                     "$C" -s
okg  "danger-decline" "Skipped"                   bash -c "printf 'n\n' | CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -r wipe /x"
okg  "danger-accept"  "WIPE /x"                   bash -c "printf 'y\n' | CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -r wipe /x"

section "HISTORY + RERUN"
newdata
"$C" -a hh 'echo hi' demo >/dev/null 2>&1
"$C" -r hh >/dev/null 2>&1; "$C" -r hh >/dev/null 2>&1
okg  "history-show"   "hh"                        "$C" --history 5
okg  "rerun-last"     "Re-running:"               "$C" -r last
newdata
okg  "history-empty"  "No run history"            "$C" --history

section "FINDINGS + REPORT"
newdata
okg  "finding-add"    "Finding recorded"          "$C" --finding high dc01 'Unauth WinRM' --evidence /tmp/x.log
okg  "finding-nohost" "Finding recorded"          "$C" --finding low - 'Verbose banner'
okc  "finding-badsev" 1                           "$C" --finding bogus h 't'
RPT="$CMDR_DATA_DIR/r.md"
"$C" --report "$RPT" >/dev/null 2>&1
okg  "report-title"   "Engagement Report"         cat "$RPT"
okg  "report-finding" "Unauth WinRM"              cat "$RPT"

section "PACKS + IMPORT/EXPORT"
newdata
okg  "pack-list"      "ctf-network"               "$C" --pack list
okg  "pack-starter"   "starter"                   "$C" --pack list
okg  "pack-load"      "Imported"                  "$C" --pack load ctf-web
okc  "pack-missing"   1                           "$C" --pack load nope
EXP="$CMDR_DATA_DIR/exp.json"
okg  "export"         "extracted"                 "$C" -x "$EXP"
newdata
okg  "import"         "Imported"                  "$C" -i "$EXP"
okc  "import-missing" 1                           "$C" -i /no/such/file.json

section "PLAYBOOKS + CHAINS"
newdata
"$C" -a a 'echo A' p >/dev/null 2>&1; "$C" -a b 'echo B' p >/dev/null 2>&1
okg  "pb-create"      "created"                   "$C" --playbook recon a b
okg  "pb-run"         "A"                          "$C" -p recon
okc  "pb-missing"     1                           "$C" -p ghostpb
okg  "chain"          "Chain completed"           "$C" --chain a b

section "NOTES + OUTPUTS"
newdata
"$C" -a n1 'echo n' demo >/dev/null 2>&1
okg  "note-add"       "Note added"                "$C" --note n1 'finding here'
okg  "note-show"      "finding here"              "$C" --notes n1
"$C" -r n1 --save >/dev/null 2>&1
okg  "outputs"        "n1_"                       "$C" --outputs

section "WORKSPACES + ISOLATION"
newdata
"$C" -a g 'echo global' x >/dev/null 2>&1
okg  "ws-switch"      "Switched to workspace"     "$C" -w proj
"$C" -a w 'echo wsonly' x >/dev/null 2>&1
okng "ws-isolated"    "global"                    "$C" -s
okg  "ws-list"        "proj"                      "$C" -W
"$C" -w default >/dev/null 2>&1
okng "ws-default-iso" "wsonly"                    "$C" -s
okc  "ws-traversal"   1                           "$C" -w '../../evil'

section "TRUST / PROJECT-LOCAL"
newdata
PROJ="$(td)"
( cd "$PROJ" && echo '{"pwn":{"command":"echo PWNED","category":"x"}}' > .cmdr.json
  okg "local-untrusted" "Ignoring untrusted"  bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -r pwn"
  okc "local-norun"     1                      bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -r pwn"
  okg "local-trust"     "Trusted"              bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' --trust"
  okg "local-runs"      "PWNED"                bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -r pwn"
  echo '{"pwn":{"command":"echo TAMPERED","category":"x"}}' > .cmdr.json
  okc "local-reblocks"  1                      bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -r pwn" )

section "UNDO"
newdata
"$C" -a u1 'echo u' x >/dev/null 2>&1
"$C" -d u1 -y >/dev/null 2>&1
okg  "undo"           "restored"                  "$C" -u
okg  "undo-applied"   "u1"                        "$C" -s
okc  "undo-none"      1                           "$C" -u

section "ENCRYPTED WORKSPACE GUARDS"
newdata
okc  "lock-default-rej" 1                          "$C" --lock-workspace
okc  "unlock-missing"   1                          "$C" --unlock-workspace ghost
"$C" -w cx >/dev/null 2>&1; "$C" -a s1 'echo s' x >/dev/null 2>&1
bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' --lock-workspace cx </dev/null" >/dev/null 2>&1
okg  "lock-data-intact" "s1"  bash -c "CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -w cx >/dev/null; CMDR_DATA_DIR='$CMDR_DATA_DIR' '$C' -s"

section "GLOBAL FLAGS / EDGE CASES"
newdata
okg  "version"        "v[0-9]+\.[0-9]+\.[0-9]+"   "$C" -V
okg  "help"           "Command Manager"          "$C" -h
okc  "invalid-opt"    1                           "$C" --nonsense
"$C" -a litarg 'echo' default >/dev/null 2>&1
okg  "end-of-opts"    "DRY RUN"                   "$C" -n -r litarg -- -n hello

section "CONCURRENCY (portable lock)"
newdata
for i in 1 2 3 4 5 6; do ( "$C" -a "c$i" "echo $i" x >/dev/null 2>&1 ) & done; wait
N=$(jq 'keys|length' "$CMDR_DATA_DIR/my_commands.json" 2>/dev/null)
if [ "$N" = "6" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("concurrency (only $N/6 landed)"); fi

echo ""
echo "════════════════════════════════════════════"
echo " RESULTS: PASS=$PASS  FAIL=$FAIL"
echo "════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then printf '  ✗ %s\n' "${FAILED[@]}"; exit 1; fi
echo " ✓ all tests passed"
