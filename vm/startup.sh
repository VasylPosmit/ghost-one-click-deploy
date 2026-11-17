#!/usr/bin/env bash
# GCE startup script. Runs as root on EVERY boot and must be idempotent.
# Never prints secrets; never uses `set -x`.
set -Eeuo pipefail

LOG=/var/log/ghost-startup.log
APP=/opt/ghost
MD=http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/ghost
MDA=http://metadata.google.internal/computeMetadata/v1/instance/attributes
MYSQL_IMAGE="mysql:8.0.46"
GHOST_IMAGE="ghost:6.76.0-alpine"
CLOUDFLARED_IMAGE="cloudflare/cloudflared:2026.11.1"

# Single instance: deploy.sh may re-run this script via ssh while it is already running.
exec 9>/run/ghost-startup.lock
flock -n 9 || { echo "ghost startup already running; exiting" >&2; exit 0; }

touch "$LOG"; chmod 600 "$LOG"
exec >>"$LOG" 2>&1

STEP="init"
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

meta_put() { # meta_put <key> <value>
  curl -fsS -X PUT --data "$2" -H "Metadata-Flavor: Google" "${MD}/$1" >/dev/null 2>&1 || log "warn: could not publish ghost/$1"
}
meta_del() {
  curl -fsS -X DELETE -H "Metadata-Flavor: Google" "${MD}/$1" >/dev/null 2>&1 || true
}
on_err() { local rc=$?; log "FAILED at step '${STEP}' (rc=${rc})"; meta_put status "error:${STEP}"; exit "$rc"; }
trap on_err ERR

retry() { # retry <attempts> <cmd...>
  local n="$1" i; shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    log "retry ${i}/${n} failed: $1"; sleep $((i * 5))
  done
  return 1
}

log "=== ghost startup begin ==="
# Clear stale values from the previous boot so consumers wait for fresh ones.
meta_del url
meta_put status "starting"

# --- swap ---------------------------------------------------------------
STEP="swap"
if [[ ! -f /swapfile ]]; then
  log "creating 1G swapfile"
  fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile

# --- docker -------------------------------------------------------------
STEP="wait-egress"
# Cloud NAT / DNS can take a moment to be usable right after boot.
for i in $(seq 1 30); do
  getent hosts deb.debian.org >/dev/null 2>&1 && curl -fsS -m 10 -o /dev/null https://deb.debian.org/ 2>/dev/null && break
  log "waiting for DNS/egress (${i}/30)"; sleep 5
done

STEP="docker-install"
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  log "installing Docker Engine + compose plugin"
  export DEBIAN_FRONTEND=noninteractive
  APT="apt-get -o DPkg::Lock::Timeout=300 -y -q"
  retry 5 $APT update
  retry 5 $APT install ca-certificates curl openssl
  install -m 0755 -d /etc/apt/keyrings
  retry 5 curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  retry 5 $APT update
  retry 5 $APT install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
# Docker Hub anonymous pull limits are per IP and Cloud NAT IPs are shared: use Google's mirror.
mkdir -p /etc/docker
if ! grep -q mirror.gcr.io /etc/docker/daemon.json 2>/dev/null; then
  printf '{\n  "registry-mirrors": ["https://mirror.gcr.io"]\n}\n' > /etc/docker/daemon.json
  systemctl restart docker 2>/dev/null || true
fi
systemctl enable --now docker
retry 10 docker info >/dev/null 2>&1

# --- app dir, secrets, compose -------------------------------------------
STEP="app-config"
install -d -m 0750 "$APP"
cd "$APP"

if [[ ! -f .env ]]; then
  log "creating .env (generated credentials; not logged)"
  root_pw="$(openssl rand -hex 24)"; db_pw="$(openssl rand -hex 24)"
  [[ -n "$root_pw" && -n "$db_pw" ]] || { log "openssl rand produced empty password"; false; }
  ( umask 077
    {
      echo "MYSQL_ROOT_PASSWORD=${root_pw}"
      echo "MYSQL_PASSWORD=${db_pw}"
      echo "GHOST_URL=http://localhost:2368"
    } > .env.tmp
    mv .env.tmp .env )
  unset root_pw db_pw
fi
chmod 600 .env

cat > docker-compose.yml <<COMPOSE
# Managed by startup.sh - rewritten on every boot.
name: ghost
services:
  mysql:
    image: ${MYSQL_IMAGE}
    container_name: mysql
    restart: unless-stopped
    command: --performance-schema=OFF --innodb-buffer-pool-size=128M --max-connections=30
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "MYSQL_PWD=\$\$MYSQL_ROOT_PASSWORD mysqladmin ping -h 127.0.0.1 -uroot --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s

  ghost:
    image: ${GHOST_IMAGE}
    container_name: ghost
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      NODE_ENV: production
      NODE_OPTIONS: --max-old-space-size=512
      security__staffDeviceVerification: "false"
      url: \${GHOST_URL}
      database__client: mysql
      database__connection__host: mysql
      database__connection__user: ghost
      database__connection__password: \${MYSQL_PASSWORD}
      database__connection__database: ghost
    volumes:
      - ghost-content:/var/lib/ghost/content
    healthcheck:
      test: ["CMD-SHELL", "H=\$\${url#https://}; wget -q -O /dev/null --header 'X-Forwarded-Proto: https' --header \"Host: \$\$H\" http://127.0.0.1:2368/ || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 18
      start_period: 90s

  cloudflared:
    image: ${CLOUDFLARED_IMAGE}
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate --protocol http2 --url http://ghost:2368

volumes:
  mysql-data:
  ghost-content:
COMPOSE
chmod 600 docker-compose.yml
docker compose config -q

# --- bring up -----------------------------------------------------------
STEP="pull-images"
retry 6 docker compose pull -q

STEP="mysql-up"
docker compose up -d mysql
# fresh cloudflared instance every boot => clean logs, exactly one current URL
STEP="tunnel-up"
URL=""
for attempt in 1 2 3 4 5; do
  docker compose up -d --force-recreate cloudflared
  for _ in $(seq 1 30); do
    URL="$(docker logs cloudflared 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | grep -v '^https://api\.' | tail -n1 || true)"
    [[ -n "$URL" ]] && break
    sleep 4
  done
  [[ -n "$URL" ]] && break
  log "no tunnel URL yet (attempt ${attempt}); backing off, then recreating cloudflared"
  sleep $((attempt * 15))   # quick tunnels can answer 429 when rate-limited
done
[[ -n "$URL" ]] || { log "cloudflared never produced a URL"; false; }
log "tunnel URL: ${URL}"

STEP="write-url"
( umask 077
  grep -v '^GHOST_URL=' .env > .env.tmp || true
  echo "GHOST_URL=${URL}" >> .env.tmp
  mv .env.tmp .env )
chmod 600 .env

STEP="ghost-up"
docker compose up -d ghost   # recreates automatically when GHOST_URL changed

STEP="ghost-health"
healthy=""
for _ in $(seq 1 60); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' ghost 2>/dev/null || true)" == "healthy" ]] && { healthy=1; break; }
  sleep 5
done
[[ -n "$healthy" ]] || { log "ghost did not become healthy"; false; }

# --- wait until the public tunnel really serves Ghost (200/302) --------------
STEP="tunnel-reachable"
code=""
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${URL}/" || true)"
  [[ "$code" == "200" || "$code" == "302" ]] && break
  sleep 5
done
[[ "$code" == "200" || "$code" == "302" ]] || { log "public tunnel URL not reachable (last http ${code:-000})"; false; }

# --- owner setup (no public port: node runs inside the ghost container) ----
STEP="owner-setup"
# Ghost's setup API is unauthenticated until the owner exists; whoever reaches the
# public URL first could claim the blog. So we claim it here, before publishing the URL.
# Request goes to localhost:2368 inside the container; Host/X-Forwarded-Proto make
# Ghost treat it as the configured https URL (no redirect). Secrets travel on stdin only.
GHOST_HOST="${URL#https://}"
NODE_SETUP='
const http=require("http");
const mode=process.argv[1], host=process.argv[2];
let inp="";process.stdin.on("data",d=>inp+=d).on("end",()=>{
  const body=mode==="post"?inp:"";
  const req=http.request({host:"127.0.0.1",port:2368,path:"/ghost/api/admin/authentication/setup/",method:mode==="post"?"POST":"GET",
    headers:{"Host":host,"X-Forwarded-Proto":"https","Origin":"https://"+host,"Accept-Version":"v6.0","Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},res=>{
    let o="";res.on("data",d=>o+=d).on("end",()=>{
      if(mode==="get"){try{process.exit(JSON.parse(o).setup[0].status===true?0:10)}catch(e){process.exit(2)}}
      process.exit(res.statusCode===201?0:3)});});
  req.on("error",()=>process.exit(4));req.end(body);});'
ghost_setup() { docker exec -i ghost node -e "$NODE_SETUP" "$@"; }
rc=0; ghost_setup get "$GHOST_HOST" </dev/null || rc=$?
if [[ "$rc" == "10" ]]; then
  ADMIN_EMAIL="$(curl -fsS -H 'Metadata-Flavor: Google' "${MDA}/admin-email" 2>/dev/null || true)"
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.invalid}"
  admin_pw="$(openssl rand -hex 16)"
  [[ -n "$admin_pw" ]] || { log "openssl rand produced empty password"; false; }
  # Persist credentials first so a crash after setup can never lose them.
  ( umask 077; printf 'email=%s\npassword=%s\n' "$ADMIN_EMAIL" "$admin_pw" > admin.txt.tmp; mv admin.txt.tmp admin.txt )
  chmod 600 admin.txt
  post_owner() {
    printf '{"setup":[{"name":"Admin","email":"%s","password":"%s","blogTitle":"Ghost on GCP"}]}' "$ADMIN_EMAIL" "$admin_pw" \
      | ghost_setup post "$GHOST_HOST"
  }
  retry 3 post_owner || { log "owner setup POST failed"; false; }
  unset admin_pw
  log "owner account created (credentials in ${APP}/admin.txt, mode 600)"
elif [[ "$rc" == "0" ]]; then
  log "owner setup already done"
else
  log "owner setup status check failed (rc=${rc})"; false
fi

STEP="publish"
meta_put url "$URL"
meta_put status "ready"
log "=== ghost startup done: ready ==="
