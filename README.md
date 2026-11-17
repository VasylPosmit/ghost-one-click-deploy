# Ghost one-click deploy

> Task: see [TASK.md](TASK.md).

## Conclusion

- **What it does:** `./deploy.sh` deploys a production Ghost blog (Ghost 6 + MySQL 8, Docker Compose) on a GCP VM in one command, with **nothing reachable directly from the internet**.
- **No public SSH, tunnels only:** the VM has no public IP. Admin shell goes through the Google IAP tunnel (the only ingress rule: tcp:22 from IAP's range); public web traffic goes through an outbound Cloudflare quick tunnel; outbound internet via Cloud NAT. The project's default world-open SSH/RDP rules are removed.
- **Secure by default:** the Ghost owner account is claimed automatically seconds after Ghost starts (the setup page is not left open on the random tunnel URL); DB and admin passwords are generated on the VM and are only readable over IAP. No mail is configured, so Ghost's new-device email check for staff login is turned off.
- **How we checked:** `loop.sh` runs destroy → deploy from zero → deploy again → `verify.sh` → reboot check; every DoD item below is a scripted PASS/FAIL. Final zero → success run on the default `e2-small`: **all PASS** (see [Verification](#verification)).
- **Calibration:** machine size is a parameter (`MACHINE_TYPE`, default `e2-small`, 2 GB). Measured on 4 tiers: the stack uses < 1 GB RAM; `e2-small` passes everything with no swap; `e2-micro` (1 GB) works but is ~10× slower. Full table and decision in [Calibration](#calibration).
- **Torn down:** after the final run, all created resources were destroyed (`verify.sh --destroyed` PASS).
- **Infra cost of this work:** ≈ **$0.15–0.25** (estimate from ~1.5 VM-hours across 4 machine sizes, ~1.5 disk-hours, Cloud NAT gateway + ~2 GB NAT processing for apt/image pulls; IAP and the Cloudflare quick tunnel are free). Exact figure appears in GCP billing after ~24 h; a €10 project budget alert was set as a guard.

## Usage

Prerequisites:
- `gcloud` installed and logged in (`gcloud auth login`), a project selected (`gcloud config set project <id>`) with billing enabled.
- Your account is **Owner** of the project (or has: Service Usage Admin, Compute Admin, IAP-secured Tunnel User, Compute OS Admin Login).
- **Use a dedicated / throwaway project:** `deploy.sh` deletes the default network's world-open `default-allow-ssh` and `default-allow-rdp` rules project-wide (requirement: no public SSH), and `destroy.sh` does not restore them — other VMs in the project lose public SSH.

```bash
./deploy.sh      # one click: build everything, print the blog URL
```

```bash
./verify.sh      # check B1, B2, C1–C5 against the running deployment
```

```bash
./destroy.sh     # remove everything deploy.sh created
```

- Blog admin password: `deploy.sh` prints the exact IAP command at the end (`gcloud compute ssh ghost-vm --tunnel-through-iap … --command 'sudo cat /opt/ghost/admin.txt'`).
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
5. **Only through tunnels** — all access (admin shell and web traffic) goes over a tunnel; nothing is reachable directly from the internet (web: outbound Cloudflare tunnel; SSH: Google IAP tunnel, the only ingress rule).

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
- [x] C5. `cloudflared` (outbound tunnel) is running — B1 proves it serves Ghost; egress works via Cloud NAT.

### Also required (checked once, not in the loop)
- [x] **Calibration measured** — 4 tiers (`e2-standard-2`, `e2-medium`, `e2-small`, `e2-micro`): memory idle/after load, swap, OOM kills, 300-request load test. Default `e2-small` confirmed (see [Calibration](#calibration)).
- [x] **No secrets in the public repo** — passwords generated on the VM, `.gitignore` for secret files, tunnel URLs redacted in logs; manual `gitleaks git .` scan before pushes (no credentials found; PR is squash-merged so early commits don't land in `main`).

## Verification

Development loop run on 2026-11-17 (`MACHINE_TYPE=e2-standard-2`), `loop.sh` summary:

```text
destroy.sh                         PASS   207s
verify --destroyed (A3)            PASS   11s
deploy.sh #1 (A1, from zero)       PASS   279s
deploy.sh #2 (A2, idempotent)      PASS   55s
verify.sh (A1 A2 B1 B2 C1-C5)      PASS   36s
verify.sh --reboot (B3)            PASS   129s
OVERALL: PASS
```

**Final zero → success run** on 2026-11-17 (default `MACHINE_TYPE=e2-small`, separate isolated stack), `loop.sh` summary:

```text
destroy.sh                         PASS   6s
verify --destroyed (A3)            PASS   11s
deploy.sh #1 (A1, from zero)       PASS   342s
deploy.sh #2 (A2, idempotent)      PASS   27s
verify.sh (A1 A2 B1 B2 C1-C5)      PASS   21s
verify.sh --reboot (B3)            PASS   115s
OVERALL: PASS
```

Machine-size measurements: see [Calibration](#calibration).

Issues found and fixed along the way:
- Debian 12 image `v20261117` kernel crashed (ext4 oops) during first boot → switched to Debian 13.
- Ghost's first-run setup page would be public on the tunnel URL → owner account auto-created on deploy.
- Checks that could pass when `gcloud` itself failed → now fail loudly.

## Calibration

**Decision: default `MACHINE_TYPE=e2-small` (2 vCPU shared, 2 GB).** Smallest tier that passes every check with headroom, no swap and no OOM kills. Use `e2-medium` if the blog expects sustained traffic (tighter p95); `e2-micro` is not recommended.

Method (`calibrate.sh`): the same VM is stopped, resized, and started on each tier, then measured: time to `ready`, `verify.sh`, `free -m` idle and after load, swap, `docker stats` RSS, `dmesg` OOM kills, and a load test of 300 requests at concurrency 10 through the public tunnel.

| tier | vCPU / RAM | start → ready | verify | mem idle / after load | swap | Ghost / MySQL RSS | load ok / fail | p50 / p95 | OOM |
|---|---|---|---|---|---|---|---|---|---|
| e2-standard-2 | 2 / 8 GB | 76 s | PASS | 881 / 952 MB | 0 | 190 / 206 MiB | 300 / 0 | 0.29 / 0.56 s | 0 |
| e2-medium | 2 / 4 GB | 81 s | PASS | 862 / 911 MB | 0 | 185 / 205 MiB | 300 / 0 | 0.29 / 0.52 s | 0 |
| **e2-small** | 2 / 2 GB | 72 s | PASS | 761 / 820 MB | 0 | 177 / 203 MiB | 300 / 0 | 0.23 / 1.46 s | 0 |
| e2-micro | 2 / 1 GB | 213 s | PASS | 620 / 673 MB | 140 MB | 194 / 83 MiB | 300 / 0 | 2.39 / 4.24 s | 0 |

Boot phases on restart (seconds, from the VM's `ghost/timings`):

| tier | docker | pull | tunnel | Ghost start | total |
|---|---|---|---|---|---|
| e2-standard-2 / e2-medium / e2-small | 3–4 | 1–2 | 10 | 11 | 27–29 |
| e2-micro | 9 | 18 | 31 | 100 | 165 |

Findings:
- **Memory is not the constraint:** the whole stack (Ghost + MySQL tuned for small RAM + cloudflared + OS) uses ~0.8–0.95 GB under load. 2 GB leaves > 1 GB headroom.
- **CPU bursts are:** `e2-small`'s p95 rises to 1.46 s (shared-core burst), still 0 failures. `e2-micro` swaps (MySQL squeezed to 83 MiB), Ghost takes 100 s to start, and median latency is ~10× higher.
- **First deploy from zero is slower than a restart:** on `e2-small` the one-time MySQL initialisation took ~107 s (final run: deploy from zero 342 s in total).
- Limits of this calibration: a single short load test through a quick tunnel (which itself caps at 200 in-flight requests); no long soak test, no write-heavy load.

## Time tracking

| | |
|---|---|
| Start | 2026-11-17 16:58 (WET) |
| Target | ~1 h |
| End | 2026-11-17 17:55 (WET) — final run validated |
| Total | 57 min |

## AI usage

Full AI conversation exports: [ai-conversations/](ai-conversations/).
