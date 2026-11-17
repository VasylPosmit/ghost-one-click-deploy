#!/usr/bin/env bash
# One-click, idempotent Ghost deploy on GCP. No public SSH, no external IP.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

START=$SECONDS
require_gcloud
[[ -f vm/startup.sh ]] || die "vm/startup.sh missing"

# 1. APIs ------------------------------------------------------------------
log "1/7 enabling APIs (compute, iap, oslogin)"
gcloud services enable compute.googleapis.com iap.googleapis.com oslogin.googleapis.com \
  --project "$PROJECT" --quiet

# 2. Project hardening (C3) -----------------------------------------------
log "2/7 hardening: removing default SSH/RDP firewall rules"
for r in default-allow-ssh default-allow-rdp; do
  if exists gcloud compute firewall-rules describe "$r" --project "$PROJECT"; then
    gcc firewall-rules delete "$r"
    log "  deleted firewall rule $r"
  else
    log "  $r already absent"
  fi
done
offenders="$(open_admin_rules)" || die "could not list firewall rules/policies"
if [[ -n "$offenders" ]]; then
  while IFS=$'\t' read -r n a; do
    log "  WARNING: firewall rule '$n' allows [$a] from 0.0.0.0/0 (not touched; not ours)"
  done <<<"$offenders"
fi

# 3. Network ---------------------------------------------------------------
log "3/7 network: ${VPC} / ${SUBNET}"
if ! exists gcloud compute networks describe "$VPC" --project "$PROJECT"; then
  gcc networks create "$VPC" --subnet-mode=custom
else log "  VPC exists"; fi
if ! exists gcloud compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT"; then
  gcc networks subnets create "$SUBNET" --network "$VPC" --region "$REGION" \
    --range "$SUBNET_RANGE" --enable-private-ip-google-access
else log "  subnet exists"; fi

# 4. Firewall: IAP SSH only -------------------------------------------------
log "4/7 firewall: ${FW_IAP} (tcp:22 from ${IAP_RANGE})"
if ! exists gcloud compute firewall-rules describe "$FW_IAP" --project "$PROJECT"; then
  gcc firewall-rules create "$FW_IAP" --network "$VPC" --direction INGRESS --action ALLOW \
    --rules tcp:22 --source-ranges "$IAP_RANGE" --target-tags "$TAG"
else log "  firewall rule exists"; fi

# 5. Router + NAT ----------------------------------------------------------
log "5/7 egress: ${ROUTER} + ${NAT}"
if ! exists gcloud compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT"; then
  gcc routers create "$ROUTER" --network "$VPC" --region "$REGION"
else log "  router exists"; fi
if ! exists gcloud compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" --project "$PROJECT"; then
  gcc routers nats create "$NAT" --router "$ROUTER" --region "$REGION" \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
else log "  NAT exists"; fi

# 6. VM --------------------------------------------------------------------
# No service account / scopes: the VM needs no Google API access. Guest attributes
# are written through the metadata server (Metadata-Flavor header only), which does
# not use SA credentials, so status/url publishing keeps working.
log "6/7 VM: ${VM} (${MACHINE_TYPE}, no external IP, no service account)"
MD_PAIRS="enable-oslogin=TRUE,enable-guest-attributes=TRUE,admin-email=${ADMIN_EMAIL}"
rerun_startup=0
if ! exists gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT"; then
  gcc instances create "$VM" --zone "$ZONE" --machine-type "$MACHINE_TYPE" \
    --network "$VPC" --subnet "$SUBNET" --no-address --tags "$TAG" \
    --image-family "$IMAGE_FAMILY" --image-project "$IMAGE_PROJECT" \
    --boot-disk-size "$DISK_SIZE" --boot-disk-type "$DISK_TYPE" \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --no-service-account --no-scopes \
    --metadata "$MD_PAIRS" \
    --metadata-from-file startup-script=vm/startup.sh
else
  log "  VM exists: refreshing metadata"
  gcc instances add-metadata "$VM" --zone "$ZONE" \
    --metadata "$MD_PAIRS" \
    --metadata-from-file startup-script=vm/startup.sh
  status="$(gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" --format='value(status)')" \
    || die "cannot describe ${VM}"
  if [[ "$status" == "TERMINATED" || "$status" == "STOPPED" ]]; then
    log "  VM is $status, starting (startup script runs on boot)"
    gcc instances start "$VM" --zone "$ZONE"
  else
    gst="$(guest_attr status)"
    if [[ "$gst" != "ready" && "$gst" != "starting" ]]; then
      log "  guest status is '${gst:-<none>}' (not ready): re-running startup script"
      rerun_startup=1
    elif [[ "$gst" == "starting" ]]; then
      log "  startup script already in progress; waiting"
    fi
  fi
fi
if (( rerun_startup )); then
  if ! vm_ssh 'sudo google_metadata_script_runner startup >/dev/null 2>&1 &'; then
    log "  IAP ssh re-run failed (see ${SSH_ERR}); resetting VM instead"
    gcc instances reset "$VM" --zone "$ZONE"
  fi
  # the old error:* status is stale until the script flips it to "starting"
  for _ in $(seq 1 12); do
    [[ "$(guest_attr status)" == error:* ]] || break
    sleep 10
  done
fi

# 7. Wait for Ghost ----------------------------------------------------------
log "7/7 waiting for Ghost (timeout ${WAIT_TIMEOUT}s)"
deadline=$((SECONDS + WAIT_TIMEOUT))
wait_ready || die "VM did not become ready (see messages above)"
url="$WAIT_URL"
log "  tunnel URL published: $(redact_url "$url")"

while (( SECONDS < deadline )); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url/" || true)"
  if [[ "$code" == "200" ]]; then break; fi
  log "  ... GET $(redact_url "$url")/ -> ${code:-000}"
  sleep 10
done
[[ "${code:-}" == "200" ]] || die "Ghost URL did not return HTTP 200 in time (last: ${code:-000})"

log "DONE in $((SECONDS - START))s"
echo
echo "Ghost:  $(redact_url "$url")   (full URL: gcloud compute instances get-guest-attributes ${VM} --zone ${ZONE} --project ${PROJECT} --query-path=ghost/url)"
echo "SSH:    $(iap_ssh_cmd)"
echo "Admin login (created by the VM, never logged):"
echo "  gcloud compute ssh ${VM} --zone ${ZONE} --tunnel-through-iap --command 'sudo cat /opt/ghost/admin.txt'"
echo "Note: quick-tunnel URL is random and changes whenever the VM reboots."
if [[ -t 1 ]]; then
  echo
  echo "Ghost:  ${url}"
  echo "Admin:  ${url}/ghost/"
fi
