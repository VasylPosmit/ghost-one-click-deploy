#!/usr/bin/env bash
# Tears down everything deploy.sh created. Tolerant of already-missing resources.
# Does not recreate default firewall rules and does not disable APIs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

require_gcloud

del_if_exists() { # del <label> <describe-cmd...> -- <delete-cmd...>
  local label="$1"; shift
  local desc=() delcmd=() seen=0
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen=1; continue; fi
    if (( seen )); then delcmd+=("$a"); else desc+=("$a"); fi
  done
  if exists "${desc[@]}"; then
    log "deleting ${label}"
    "${delcmd[@]}"
  else
    log "${label}: not found, skipping"
  fi
}

del_if_exists "VM ${VM}" gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" -- \
  gcc instances delete "$VM" --zone "$ZONE" --delete-disks=all
del_if_exists "firewall ${FW_IAP}" gcloud compute firewall-rules describe "$FW_IAP" --project "$PROJECT" -- \
  gcc firewall-rules delete "$FW_IAP"
del_if_exists "NAT ${NAT}" gcloud compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" --project "$PROJECT" -- \
  gcc routers nats delete "$NAT" --router "$ROUTER" --region "$REGION"
del_if_exists "router ${ROUTER}" gcloud compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT" -- \
  gcc routers delete "$ROUTER" --region "$REGION"
del_if_exists "subnet ${SUBNET}" gcloud compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT" -- \
  gcc networks subnets delete "$SUBNET" --region "$REGION"
del_if_exists "VPC ${VPC}" gcloud compute networks describe "$VPC" --project "$PROJECT" -- \
  gcc networks delete "$VPC"

log "destroy complete"
