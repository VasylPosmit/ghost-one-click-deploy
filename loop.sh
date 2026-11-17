#!/usr/bin/env bash
# URLs are redacted in logs unless SHOW_URL=1. On failure it runs destroy.sh unless KEEP=1; on success infra stays up.
# Execution loop: destroy -> verify --destroyed -> deploy (A1) -> deploy again (A2)
#                 -> verify -> verify --reboot. Logs to logs/run-<timestamp>.log.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

mkdir -p logs
LOGFILE="logs/run-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOGFILE") 2>&1

NAMES=(); RESULTS=(); DURS=()
record() { NAMES+=("$1"); RESULTS+=("$2"); DURS+=("$3"); }
overall=0

run() { # run <label> <cmd...>; sets LAST_RC, LAST_SECS
  local label="$1"; shift
  echo; echo "=== ${label} ==="
  local t=$SECONDS
  "$@"; LAST_RC=$?
  LAST_SECS=$((SECONDS - t))
  record "$label" "$([[ $LAST_RC == 0 ]] && echo PASS || echo FAIL)" "${LAST_SECS}s"
  (( LAST_RC == 0 )) || overall=1
}

summary() {
  # Failure => clean up so no billable resources linger (KEEP=1 keeps them for debugging).
  # Success => leave infra up; the conductor decides when to destroy.
  if (( overall != 0 )) && [[ "${KEEP:-0}" != "1" ]]; then
    echo; echo "=== failure cleanup: destroy.sh (set KEEP=1 to skip) ==="
    ./destroy.sh || echo "WARNING: cleanup destroy.sh failed; check the project manually"
  elif (( overall != 0 )); then
    echo; echo "KEEP=1: failure, infrastructure left up"
  fi
  echo; echo "================ SUMMARY ================"
  printf '%-34s %-6s %s\n' STEP RESULT DURATION
  for i in "${!NAMES[@]}"; do printf '%-34s %-6s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${DURS[$i]}"; done
  echo "log: ${LOGFILE}"
  (( overall == 0 )) && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
  exit "$overall"
}

run "destroy.sh" ./destroy.sh; destroy_rc=$LAST_RC
A3_RC=$destroy_rc run "verify --destroyed (A3)" ./verify.sh --destroyed

run "deploy.sh #1 (A1, from zero)" ./deploy.sh; A1_RC=$LAST_RC
(( A1_RC == 0 )) || summary
before="$(resource_snapshot)"

run "deploy.sh #2 (A2, idempotent)" ./deploy.sh; A2_RC=$LAST_RC
after="$(resource_snapshot)"
if [[ "$before" != "$after" ]]; then
  echo "A2: resource snapshot CHANGED between runs:"; diff <(echo "$before") <(echo "$after")
  A2_RC=1; overall=1
fi
echo "A2 snapshot unchanged: $([[ $A2_RC == 0 ]] && echo yes || echo no)"

A1_RC=$A1_RC A2_RC=$A2_RC run "verify.sh (A1 A2 B1 B2 C1-C5)" ./verify.sh
run "verify.sh --reboot (B3)" ./verify.sh --reboot
summary
