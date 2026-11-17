#!/usr/bin/env bash
# Fast inner loop against an EXISTING VM: push the current vm/startup.sh as startup-script
# metadata, re-run it over IAP ssh, wait for ghost/status=ready, then ./verify.sh (fast mode).
# Does not create or destroy infrastructure; run ./deploy.sh first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

START=$SECONDS
require_gcloud
[[ -f vm/startup.sh ]] || die "vm/startup.sh missing"

exists gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" \
  || die "VM ${VM} does not exist in ${PROJECT}/${ZONE}: run ./deploy.sh first"
vmstatus="$(gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" --format='value(status)')" \
  || die "cannot describe ${VM}"
[[ "$vmstatus" == "RUNNING" ]] || die "VM ${VM} is ${vmstatus}, not RUNNING: run ./deploy.sh (it starts or repairs the VM)"

log "dev 1/4 pushing vm/startup.sh as startup-script metadata"
gcc instances add-metadata "$VM" --zone "$ZONE" --metadata-from-file startup-script=vm/startup.sh

log "dev 2/4 re-running startup script over IAP ssh"
serial_baseline
vm_ssh 'nohup sudo google_metadata_script_runner startup >/dev/null 2>&1 </dev/null &' \
  || die "IAP ssh failed (see ${SSH_ERR}); if the VM is wedged, run ./deploy.sh"

# The previous run's ready/error:* status is stale until the script publishes "starting".
for _ in $(seq 1 12); do
  st="$(guest_attr status)"
  [[ "$st" == ready || "$st" == error:* ]] || break
  sleep 5
done

log "dev 3/4 waiting for ready (timeout ${WAIT_TIMEOUT}s)"
wait_ready || die "VM did not become ready (see messages above)"
log "  tunnel URL: $(redact_url "$WAIT_URL")"

log "dev 4/4 verify.sh (fast: B1 B2 C1-C5)"
rc=0
./verify.sh || rc=$?
log "dev loop finished in $((SECONDS - START))s (verify rc=${rc})"
exit "$rc"
