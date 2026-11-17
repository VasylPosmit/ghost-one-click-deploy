#!/usr/bin/env bash
# Hardware calibration: step the EXISTING VM down machine-type tiers and measure each.
# Per tier: stop -> set-machine-type -> start -> wait ready -> verify.sh (fast)
#           -> memory idle -> load test (N requests, C concurrent) -> memory after + OOM kills.
# Usage: TIERS="e2-medium e2-small e2-micro" REQS=300 CONC=10 ./calibrate.sh
# Results: logs/calibration-<ts>.md (logs/ is gitignored; copy the table into README).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh
require_gcloud

TIERS="${TIERS:-e2-medium e2-small e2-micro}"
REQS="${REQS:-300}"
CONC="${CONC:-10}"
mkdir -p logs
OUT="logs/calibration-$(date -u +%Y%m%dT%H%M%SZ).md"
exists gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" || die "VM ${VM} not found — run ./deploy.sh first"

echo "| tier | vCPU / RAM | boot→ready | verify | mem used idle (MB) | mem used after load (MB) | swap used (MB) | ghost / mysql RSS | load ${REQS} req c=${CONC}: ok / fail | p50 / p95 (s) | OOM kills |" > "$OUT"
echo "|---|---|---|---|---|---|---|---|---|---|---|" >> "$OUT"

mem_used() { vm_ssh "free -m | awk '/^Mem:/ {print \$3}'"; }
swap_used() { vm_ssh "free -m | awk '/^Swap:/ {print \$3}'"; }

for tier in $TIERS; do
  log "=== tier ${tier} ==="
  prev="$(guest_attr url)"
  gcc instances stop "$VM" --zone "$ZONE" >/dev/null || die "stop failed"
  gcc instances set-machine-type "$VM" --zone "$ZONE" --machine-type "$tier" >/dev/null || die "set-machine-type ${tier} failed"
  spec="$(gcloud compute machine-types describe "$tier" --zone "$ZONE" --project "$PROJECT" --format='value(guestCpus,memoryMb)' | awk '{printf "%s / %.1f GB", $1, $2/1024}')"
  t0=$SECONDS
  gcc instances start "$VM" --zone "$ZONE" >/dev/null || die "start failed"
  SERIAL_OFF=""
  if ! wait_ready "$prev"; then
    echo "| ${tier} | ${spec} | FAILED to become ready | – | – | – | – | – | – | – | – |" >> "$OUT"
    log "tier ${tier}: not ready — stopping calibration here"; break
  fi
  boot=$((SECONDS - t0))
  url="$WAIT_URL"
  ./verify.sh >/dev/null 2>&1 && vres=PASS || vres=FAIL
  idle="$(mem_used)"
  # load test from this machine through the public tunnel
  lat="logs/lat-${tier}.txt"; : > "$lat"
  seq "$REQS" | xargs -P "$CONC" -I{} curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 30 "$url/" >> "$lat"
  ok="$(awk '$1==200' "$lat" | wc -l | tr -d ' ')"; fail=$((REQS - ok))
  p50="$(awk '$1==200 {print $2}' "$lat" | sort -n | awk '{a[NR]=$1} END{if(NR) printf "%.2f", a[int(NR*0.5)>0?int(NR*0.5):1]}')"
  p95="$(awk '$1==200 {print $2}' "$lat" | sort -n | awk '{a[NR]=$1} END{if(NR) printf "%.2f", a[int(NR*0.95)>0?int(NR*0.95):1]}')"
  after="$(mem_used)"; swp="$(swap_used)"
  rss="$(vm_ssh "sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'" | awk '/ghost-ghost|ghost$|^ghost/ {g=$2} /mysql/ {m=$2} END{print g " / " m}')"
  oom="$(vm_ssh "sudo dmesg | grep -ci 'out of memory\|oom-kill' || true")"
  row="| ${tier} | ${spec} | ${boot}s | ${vres} | ${idle} | ${after} | ${swp} | ${rss} | ${ok} / ${fail} | ${p50} / ${p95} | ${oom} |"
  echo "$row" >> "$OUT"; log "$row"
done
echo; cat "$OUT"
