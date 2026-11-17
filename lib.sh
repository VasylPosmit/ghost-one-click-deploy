# shellcheck shell=bash
# Shared config + helpers. Sourced by deploy.sh / destroy.sh / verify.sh / loop.sh.
# No secrets live here; everything is overridable through the environment.

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.invalid}"
SHOW_URL="${SHOW_URL:-0}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-${REGION}-b}"            # follows REGION unless set
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
DISK_SIZE="${DISK_SIZE:-20GB}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
NAME_PREFIX="${NAME_PREFIX:-ghost}"
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-13}"      # debian-12 image 20261117 hit a kernel ext4 oops; use 13 (kernel 6.12)
IMAGE_PROJECT="${IMAGE_PROJECT:-debian-cloud}"

VPC="${NAME_PREFIX}-vpc"
SUBNET="${NAME_PREFIX}-subnet"
SUBNET_RANGE="10.10.0.0/24"
FW_IAP="${NAME_PREFIX}-allow-iap-ssh"
IAP_RANGE="35.235.240.0/20"
ROUTER="${NAME_PREFIX}-router"
NAT="${NAME_PREFIX}-nat"
VM="${NAME_PREFIX}-vm"
TAG="${NAME_PREFIX}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"   # seconds to wait for Ghost to come up

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts()  { date -u +%H:%M:%S; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }

# URL shown in logs: redacted unless SHOW_URL=1.
redact_url() { if [[ "$SHOW_URL" == "1" ]]; then printf '%s' "$1"; else printf 'https://<redacted>.trycloudflare.com'; fi; }

# Existence probe: exists_rc gcloud ... describe ...
# rc 0 = exists, 1 = definitively absent ("not found"), 2 = real error (stderr is shown).
exists_rc() {
  local err rc
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  (( rc == 0 )) && return 0
  if grep -qi 'not found' <<<"$err"; then return 1; fi
  printf '%s\n' "$err" >&2
  return 2
}
# exists: 0/1 as above, but a real gcloud error aborts the script.
exists() {
  exists_rc "$@"; local rc=$?
  (( rc == 2 )) && die "gcloud failed while probing: ${*:1:4}"
  return "$rc"
}

require_gcloud() {
  command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
  local acct
  acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)"
  [[ -n "$acct" ]] || die "no active gcloud account. Run: gcloud auth login"
  [[ -n "$PROJECT" ]] || die "no project: set PROJECT=<id> or run: gcloud config set project <id>"
  gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1 \
    || die "cannot access project '${PROJECT}' (gcloud projects describe failed)"
  log "gcloud ok, project=${PROJECT} region=${REGION} zone=${ZONE}"
}

gcc() { gcloud compute "$@" --project "$PROJECT" --quiet; }

# Print guest attribute ghost/<key> (empty if missing).
guest_attr() {
  local key="$1" v
  v="$(gcloud compute instances get-guest-attributes "$VM" --zone "$ZONE" --project "$PROJECT" \
        --query-path="ghost/${key}" --format='value(value)' 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    # fallback: parse JSON output
    v="$(gcloud compute instances get-guest-attributes "$VM" --zone "$ZONE" --project "$PROJECT" \
          --query-path="ghost/${key}" --format=json 2>/dev/null \
          | sed -n 's/.*"value": *"\([^"]*\)".*/\1/p' | head -n1 || true)"
  fi
  printf '%s' "$v"
}

# Enabled INGRESS allow-rules in the project that expose tcp:22 / tcp:3389 / all tcp to 0.0.0.0/0 or ::/0.
# Covers VPC firewall rules and (best effort) global network firewall policies.
# Prints "name<TAB>allowed" per offender. Returns non-zero if a gcloud call really fails.
open_admin_rules() {
  local vpc pols p out
  vpc="$(gcloud compute firewall-rules list --project "$PROJECT" \
    --format='value(name,direction,disabled,sourceRanges.list(),allowed[].map().firewall_rule().list())')" || return 1
  awk -F'\t' '
    function covers(spec, port,   a, lo, hi) {
      if (spec == "") return 1
      if (index(spec, "-")) { split(spec, a, "-"); lo = a[1] + 0; hi = a[2] + 0 } else { lo = hi = spec + 0 }
      return (port >= lo && port <= hi)
    }
    $2 == "INGRESS" && tolower($3) != "true" && (index($4, "0.0.0.0/0") || index($4, "::/0")) {
      n = split($5, items, ",")
      for (i = 1; i <= n; i++) {
        it = items[i]
        if (it == "all" || it == "tcp" || it == "6") { print $1 "\t" $5; break }
        if (it ~ /^(tcp|6):/) {
          spec = substr(it, index(it, ":") + 1)
          if (covers(spec, 22) || covers(spec, 3389)) { print $1 "\t" $5; break }
        }
      }
    }' <<<"$vpc"
  # Network firewall policies (project-level). Empty list is fine; a failing list is an error.
  pols="$(gcloud compute network-firewall-policies list --global --project "$PROJECT" --format='value(name)')" || return 1
  for p in $pols; do
    out="$(gcloud compute network-firewall-policies describe "$p" --global --project "$PROJECT" --flatten=rules \
      --format='value(rules.ruleName,rules.direction,rules.disabled,rules.action,rules.match.srcIpRanges.list(),rules.match.layer4Configs.list())')" || return 1
    awk -F'\t' -v pol="$p" '
      $2 == "INGRESS" && tolower($3) != "true" && $4 == "allow" && (index($5, "0.0.0.0/0") || index($5, "::/0")) {
        l4 = $6; hit = 0
        if (l4 ~ /ipProtocol.: .(all|tcp|6)./) {
          if (l4 !~ /ports/ || l4 ~ /ipProtocol.: .all./) hit = 1
          else {
            s = l4; while (match(s, /[0-9]+(-[0-9]+)?/)) {
              tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
              if (index(tok, "-")) { split(tok, a, "-"); if (a[1] <= 22 && 22 <= a[2] || a[1] <= 3389 && 3389 <= a[2]) hit = 1 }
              else if (tok == "22" || tok == "3389") hit = 1
            }
          }
        }
        if (hit) print "policy:" pol "/" $1 "\t" l4
      }' <<<"$out"
  done
}

# Stable snapshot of everything we own (used for idempotency comparison).
resource_snapshot() {
  {
    gcloud compute instances list --project "$PROJECT" --filter="name=${VM}" --format='value(name,id,creationTimestamp)'
    gcloud compute disks list --project "$PROJECT" --filter="name=${VM}" --format='value(name,id)'
    gcloud compute firewall-rules list --project "$PROJECT" --filter="name=${FW_IAP}" --format='value(name,id)'
    gcloud compute routers list --project "$PROJECT" --filter="name=${ROUTER}" --format='value(name,id)'
    gcloud compute routers nats list --router "$ROUTER" --region "$REGION" --project "$PROJECT" --format='value(name)' 2>/dev/null || true
    gcloud compute networks subnets list --project "$PROJECT" --filter="name=${SUBNET}" --format='value(name,id)'
    gcloud compute networks list --project "$PROJECT" --filter="name=${VPC}" --format='value(name,id)'
  } | sort
}

iap_ssh_cmd() {
  printf 'gcloud compute ssh %s --zone %s --project %s --tunnel-through-iap' "$VM" "$ZONE" "$PROJECT"
}

# IAP ssh helper; stderr goes to logs/ssh-<ts>.err (not /dev/null) so failures stay debuggable.
SSH_OPTS=(--zone "$ZONE" --project "$PROJECT" --tunnel-through-iap --quiet --strict-host-key-checking=no)
SSH_ERR="${LIB_DIR}/logs/ssh-$(date -u +%Y%m%dT%H%M%SZ).err"
vm_ssh() { mkdir -p "${LIB_DIR}/logs"; gcloud compute ssh "$VM" "${SSH_OPTS[@]}" --command "$1" 2>>"$SSH_ERR"; }

# ---- fail-fast wait for the VM -------------------------------------------------
# Serial console tail: SERIAL_OFF is the byte offset already seen, so each read only
# fetches new output. gcloud prints the next offset on stderr ("--start=NNN").
SERIAL_OFF=""
SERIAL_OUT=""
serial_fetch() { # sets SERIAL_OUT (new output) and advances SERIAL_OFF
  local errf n
  errf="$(mktemp)"
  SERIAL_OUT="$(gcloud compute instances get-serial-port-output "$VM" --zone "$ZONE" --project "$PROJECT" \
    --start "${SERIAL_OFF:-0}" 2>"$errf" || true)"
  n="$(sed -n 's/.*--start=\([0-9][0-9]*\).*/\1/p' "$errf" | tail -n1)"
  if [[ -n "$n" ]]; then SERIAL_OFF="$n"; fi
  rm -f "$errf"
}
# Skip output that predates this wait (e.g. a panic from a previous boot).
serial_baseline() { SERIAL_OFF=0; serial_fetch; SERIAL_OFF="${SERIAL_OFF:-0}"; }
# Return 1 (printing the lines) if new serial output shows a kernel panic/oops/BUG.
serial_check() {
  local hits
  serial_fetch
  hits="$(grep -E 'Kernel panic|Oops:|BUG: ' <<<"$SERIAL_OUT" | head -n 10 || true)"
  [[ -z "$hits" ]] && return 0
  log "kernel fault on the serial console:" >&2
  printf '%s\n' "$hits" >&2
  return 1
}

# wait_ready [prev_url]: poll until ghost/status=ready and ghost/url is set (and differs
# from prev_url, if given). Sets WAIT_URL. Returns 1 (message on stderr) when the VM
# reports error:*, the serial console shows a kernel fault, or WAIT_TIMEOUT elapses.
# Prints every status transition with a timestamp and seconds since the wait started.
WAIT_URL=""
wait_ready() {
  local prev="${1:-}" t0=$SECONDS st last="" u n=0 tm
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  WAIT_URL=""
  [[ -n "$SERIAL_OFF" ]] || serial_baseline
  while (( SECONDS < deadline )); do
    n=$((n + 1))
    st="$(guest_attr status)"
    if [[ "$st" != "$last" ]]; then
      log "  VM status: ${last:-<none>} -> ${st:-<not reported yet>} (+$((SECONDS - t0))s)"
      last="$st"
    fi
    case "$st" in
      error:*)
        log "VM reported ${st}. Debug: $(iap_ssh_cmd) --command 'sudo tail -n 80 /var/log/ghost-startup.log'" >&2
        return 1 ;;
      ready)
        u="$(guest_attr url)"
        if [[ -n "$u" && "$u" != "$prev" ]]; then
          WAIT_URL="$u"
          tm="$(guest_attr timings)"
          [[ -z "$tm" ]] || log "  VM phase timings (s): ${tm}"
          return 0
        fi ;;
    esac
    if (( n % 3 == 0 )); then serial_check || return 1; fi
    sleep 5
  done
  log "timed out after ${WAIT_TIMEOUT}s waiting for ghost/status=ready (last status: ${last:-<none>}). Debug: $(iap_ssh_cmd) --command 'sudo tail -n 80 /var/log/ghost-startup.log'" >&2
  return 1
}
