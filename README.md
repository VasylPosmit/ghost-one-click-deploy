# Ghost one-click deploy

> Task: see [TASK.md](TASK.md).

## Conclusion

- **What it does:** `./deploy.sh` deploys a production Ghost blog (Ghost 6 + MySQL 8 + Cloudflare tunnel, Docker Compose) on a GCP VM in one command, with **zero inbound ports open to the internet**.
- **No public SSH:** the VM has no public IP; SSH is only possible through Google IAP (firewall allows tcp:22 from IAP's range only), and the project's default world-open SSH/RDP rules are removed.
- **Tunnels only:** admin shell via the IAP tunnel; public web traffic via an outbound Cloudflare quick tunnel; outbound internet via Cloud NAT.
- **Secure by default:** the Ghost owner account is created automatically (no open setup page); DB and admin passwords are generated on the VM and never leave it except over IAP.
- **How we checked:** `loop.sh` runs destroy → deploy from zero → deploy again → `verify.sh` → reboot check; every DoD item below is a scripted PASS/FAIL. Result: **all PASS** (see [Verification](#verification)).
- **Calibration:** _in progress_ — the machine is stepped down tier by tier (`e2-standard-2` → `e2-medium` → `e2-small` → `e2-micro`) with memory and load measurements; the chosen default is recorded in [Calibration](#calibration).

## Usage

Prerequisites: `gcloud` installed and logged in (`gcloud auth login`), a project selected (`gcloud config set project <id>`) with billing enabled.

```bash
./deploy.sh      # one click: build everything, print the blog URL
```

```bash
./verify.sh      # check B1, B2, C1–C5 against the running deployment
```

```bash
./destroy.sh     # remove everything deploy.sh created
```

- Blog admin password: `gcloud compute ssh ghost-vm --zone europe-west1-b --tunnel-through-iap --command 'sudo cat /opt/ghost/admin.txt'`
- Settings are env overrides at the top of [lib.sh](lib.sh) (`MACHINE_TYPE`, `REGION`, `ZONE`, `ADMIN_EMAIL`, …).
- Dev tools: `loop.sh` (full proof), `dev.sh` (fast iteration on a running VM, ~1.5 min), `calibrate.sh` (machine-size measurements).

## Architecture

```text
 Internet ──HTTPS──▶ Cloudflare edge ◀──outbound tunnel── cloudflared ┐
                                                                        │ docker network
 Admin ──gcloud ssh──▶ Google IAP ──tcp:22 (35.235.240.0/20 only)──▶  ghost-vm (no public IP, no SA)
                                                                        │  ghost:6 ── mysql:8
                                                     Cloud NAT ◀────────┘  (egress: apt, image pulls)
```

## Assumptions based on Requirements

1. **One-click script** — a single command provisions everything end-to-end, no manual console steps; re-runnable (idempotent) with a matching teardown.
2. **Ghost blog platform** — a working production Ghost (official image + MySQL 8), persistent data, reachable at a URL.
3. **At a cloud provider** — a real cloud VM provisioned as code (provider: **GCP**).
4. **No public SSH access** — port 22 is not exposed to the internet; no inbound SSH rule in the firewall/security group.
5. **Only through tunnels** — all access (admin shell and web traffic) goes over an outbound-initiated tunnel; zero inbound ports open.

Framing: an *infrastructure* task — proven by actually running it, with a calibrated machine size and no secrets in this public repo.

## Definition of Done

Each item is one PASS/FAIL assertion in `verify.sh`, proven by a **zero → success run** of `loop.sh`.

### A. One click
- [x] A1. `./deploy.sh` exits 0 from an empty project; only prerequisite is a logged-in `gcloud` (script fails fast otherwise).
- [x] A2. Second `./deploy.sh` run exits 0 and creates no duplicates (idempotent).
- [x] A3. `./destroy.sh` exits 0 and leaves zero instances, disks, routers/NAT, firewall rules, VPC created by us.

### B. Ghost works
- [x] B1. Public URL returns HTTP 200 with Ghost markup.
- [x] B2. `<url>/ghost/` (admin) returns 200 with Ghost admin markup.
- [x] B3. Containers (`ghost`, `mysql`, `cloudflared`) come back after `sudo reboot`; B1/B2 pass again on the new tunnel URL.

### C. No public SSH, tunnels only
- [x] C1. VM has no external IP (IPv4 or IPv6).
- [x] C2. Only ingress rule in our VPC = tcp:22 from `35.235.240.0/20` (IAP).
- [x] C3. No firewall rule in the whole project allows tcp:22 or tcp:3389 from `0.0.0.0/0` (default network's `default-allow-ssh` / `default-allow-rdp` removed).
- [x] C4. `gcloud compute ssh --tunnel-through-iap` runs a command on the VM successfully.
- [x] C5. Web traffic is served by `cloudflared` (outbound tunnel); egress works via Cloud NAT.

### Also required (checked once, not in the loop)
- [ ] **Calibration done** — machine size chosen from measurements, not guessed (see [Calibration](#calibration)).
- [x] **No secrets in the public repo** — passwords generated on the VM, `.gitignore` for secret files, tunnel URLs redacted in logs, `gitleaks` scan of full history clean before every push.

## Calibration

_In progress — results table from `calibrate.sh` goes here, with the keep/resize decision._

## Verification

Loop run on 2026-11-17 (`MACHINE_TYPE=e2-standard-2`), `loop.sh` summary:

```text
destroy.sh                         PASS   207s
verify --destroyed (A3)            PASS   11s
deploy.sh #1 (A1, from zero)       PASS   279s
deploy.sh #2 (A2, idempotent)      PASS   55s
verify.sh (A1 A2 B1 B2 C1-C5)      PASS   36s
verify.sh --reboot (B3)            PASS   129s
OVERALL: PASS
```

_Final zero → success run on the calibrated machine size: pending._

Issues found and fixed along the way:
- Debian 12 image `v20261117` kernel crashed (ext4 oops) during first boot → switched to Debian 13.
- Ghost's first-run setup page would be public on the tunnel URL → owner account auto-created on deploy.
- Checks that could pass when `gcloud` itself failed → now fail loudly.

## Time tracking

| | |
|---|---|
| Start | 2026-11-17 16:58 (WET) |
| Target | ~1 h |
| End | _TBD_ |

## AI usage

Full AI conversation exports: [ai-conversations/](ai-conversations/).
