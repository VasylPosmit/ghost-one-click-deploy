#!/usr/bin/env bash
# Prints PASS/FAIL per Definition-of-Done id. Exits non-zero on any FAIL.
# Modes:  (default) B1 B2 C1-C5 [+A1/A2 if A1_RC/A2_RC supplied by loop.sh]
#         --reboot     reset the VM, wait for a NEW url, re-run B1/B2/C4 => B3
#         --destroyed  A3: none of our resources exist
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

MODE="${1:-default}"
FAILS=0
require_gcloud

pass() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-3s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP  %-3s %s\n' "$1" "$2"; }
# check <id> <description> <function>
check() { if "$3"; then pass "$1" "$2"; else fail "$1" "$2"; fi; }

URL=""
get_url() { URL="$(guest_attr url)"; [[ -n "$URL" ]]; }

# ---- B -------------------------------------------------------------------
http_body_ok() { # retries ~90s to ride out DNS/tunnel warm-up
  local i code
  for i in $(seq 1 18); do
    code="$(curl -s -L --max-time 15 -o "$1" -w '%{http_code}' "$2" || true)"
    [[ "$code" == "200" ]] && return 0
    sleep 5
  done
  return 1
}
b1() {
  get_url || return 1
  local f; f="$(mktemp)"
  http_body_ok "$f" "$URL/" && grep -q '<meta name="generator" content="Ghost' "$f"
  local rc=$?; rm -f "$f"; return $rc
}
b2() {
  get_url || return 1
  local f; f="$(mktemp)"
  http_body_ok "$f" "$URL/ghost/" && grep -qiE 'ghost-admin|<title>Ghost|/ghost/assets/|ghost-admin/config' "$f"
  local rc=$?; rm -f "$f"; return $rc
}
b3_containers() {
  local out; out="$(vm_ssh 'sudo docker ps --format "{{.Names}}"')" || return 1
  for c in ghost mysql cloudflared; do grep -qx "$c" <<<"$out" || return 1; done
}

# ---- C -------------------------------------------------------------------
c1() {
  local ips
  ips="$(gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" \
        --format='value(networkInterfaces[].accessConfigs[].natIP,networkInterfaces[].accessConfigs[].name,networkInterfaces[].ipv6AccessConfigs[].externalIpv6,networkInterfaces[].ipv6AccessConfigs[].name)')" || return 1
  [[ -z "${ips//[[:space:]]/}" ]]
}
c2() {
  local rules
  rules="$(gcloud compute firewall-rules list --project "$PROJECT" \
    --format='value(name,network.basename(),direction,disabled,sourceRanges.list(),allowed[].map().firewall_rule().list())' |
    awk -F'\t' -v vpc="$VPC" '$2 == vpc && $3 == "INGRESS" && tolower($4) != "true"')" || return 1
  [[ "$(grep -c . <<<"$rules")" == "1" ]] || return 1
  awk -F'\t' -v n="$FW_IAP" -v r="$IAP_RANGE" '$1 == n && $5 == r && $6 == "tcp:22" { ok = 1 } END { exit !ok }' <<<"$rules"
}
c3() {
  local out
  out="$(open_admin_rules)" || { echo "C3: gcloud listing failed" >&2; return 1; }
  [[ -z "$out" ]]
}
c4() { b3_containers; }
c5() {
  vm_ssh 'sudo docker ps --filter name=^cloudflared$ --filter status=running -q | grep -q . && curl -s -o /dev/null -m 15 -w "%{http_code}" https://cloudflare.com/cdn-cgi/trace | grep -qE "^(200|30[0-9])$"'
}

# ---- A -------------------------------------------------------------------
a3() { # a probe error counts as FAIL, never as "absent"
  local rc out
  out="$(gcloud compute instances list --project "$PROJECT" --filter="name=${VM}" --format='value(name)')" || return 1
  [[ -z "$out" ]] || return 1
  out="$(gcloud compute disks list --project "$PROJECT" --filter="name=${VM}" --format='value(name)')" || return 1
  [[ -z "$out" ]] || return 1
  absent gcloud compute firewall-rules describe "$FW_IAP" --project "$PROJECT" || return 1
  absent gcloud compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" --project "$PROJECT" || return 1
  absent gcloud compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT" || return 1
  absent gcloud compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT" || return 1
  absent gcloud compute networks describe "$VPC" --project "$PROJECT" || return 1
  return 0
}
absent() { exists_rc "$@"; [[ $? == 1 ]]; }  # true only on a definitive "not found"
rc_check() { # rc_check <id> <desc> <rc-or-empty>   (values handed in by loop.sh)
  if [[ -z "$3" ]]; then skip "$1" "$2 (asserted by loop.sh; not supplied)"
  elif [[ "$3" == "0" ]]; then pass "$1" "$2"; else fail "$1" "$2 (rc=$3)"; fi
}

reboot_flow() {
  local prev; prev="$(guest_attr url)"
  log "rebooting ${VM} from inside via IAP ssh (previous url: $(redact_url "${prev:-none}"))"
  vm_ssh 'sudo systemctl reboot' || true   # ssh drops while the VM goes down; non-zero is expected
  sleep 20
  local deadline=$((SECONDS + WAIT_TIMEOUT)) st u
  while (( SECONDS < deadline )); do
    st="$(guest_attr status)"; u="$(guest_attr url)"
    if [[ "$st" == "ready" && -n "$u" && "$u" != "$prev" ]]; then log "new url published after reboot"; return 0; fi
    if [[ "$st" == error:* ]]; then log "VM reported $st"; return 1; fi
    log "  ... waiting (status=${st:-?})"; sleep 15
  done
  return 1
}

case "$MODE" in
  --destroyed)
    rc_check A3 "destroy.sh exited 0" "${A3_RC:-}"
    check A3 "no instance/disk/firewall/NAT/router/subnet/VPC remain" a3
    ;;
  --reboot)
    if reboot_flow; then
      pass B3 "VM rebooted and published a new tunnel URL"
      b1 && pass B3 "B1 passes again after reboot" || fail B3 "B1 after reboot"
      b2 && pass B3 "B2 passes again after reboot" || fail B3 "B2 after reboot"
      c4 && pass B3 "ghost, mysql, cloudflared running after reboot (via IAP ssh)" || fail B3 "containers after reboot"
    else
      fail B3 "VM did not come back with a new ready URL"
    fi
    ;;
  default)
    rc_check A1 "deploy.sh exited 0 from empty project" "${A1_RC:-}"
    rc_check A2 "second deploy.sh exited 0 with no resource changes" "${A2_RC:-}"
    check B1 "URL returns 200 with Ghost generator markup" b1
    check B2 "/ghost/ returns 200" b2
    check C1 "VM has no external IP" c1
    check C2 "only ingress rule in ${VPC} is tcp:22 from ${IAP_RANGE}" c2
    check C3 "no enabled rule in project exposes tcp:22/3389 to 0.0.0.0/0" c3
    check C4 "IAP ssh works; ghost/mysql/cloudflared running" c4
    check C5 "cloudflared running and VM has egress (Cloud NAT)" c5
    ;;
  *) echo "usage: $0 [--reboot|--destroyed]" >&2; exit 2 ;;
esac

echo
if (( FAILS )); then echo "RESULT: ${FAILS} FAIL"; exit 1; fi
echo "RESULT: all PASS"
