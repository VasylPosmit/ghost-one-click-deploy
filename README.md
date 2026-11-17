# Ghost one-click deploy

> Task: see [TASK.md](TASK.md).

## Time tracking

| | |
|---|---|
| Start | 2026-11-17 16:58 (WET) |
| Target | ~1 h |
| End | _TBD_ |

## Requirements (as interpreted)

1. **One-click script** — a single command provisions everything end-to-end, no manual console steps; re-runnable (idempotent) with a matching teardown.
2. **Ghost blog platform** — a working production Ghost (official image + MySQL 8), persistent data, reachable at a URL.
3. **At a cloud provider** — a real cloud VM provisioned as code (provider: **GCP**).
4. **No public SSH access** — port 22 is not exposed to the internet; no inbound SSH rule in the firewall/security group.
5. **Only through tunnels** — all access (admin shell and web traffic) goes over an outbound-initiated tunnel; zero inbound ports open.

Framing: this is an *infrastructure* task — the deliverable is proven by actually running it, with deliberate machine sizing, cost control, and no secrets in this public repo.

## How work is verified

Two kinds of requirements:

| Kind | What | How it's checked |
|---|---|---|
| **DoD (A–C)** | Functional, binary pass/fail | Automated in the **execution loop**: `destroy.sh` → `deploy.sh` → `verify.sh`. Repeat until `verify.sh` is all green from zero. |
| **Quality requirements (D–G)** | Required too, but judgement / one-off / ongoing | Checked manually once, evidence recorded in [Verification](#verification). Not part of the loop. |

Why split: the loop must be fast and deterministic. A–C are assertions a script can make; D–G need measurement, judgement, or are process rules (e.g. secret scan before push).

## Definition of Done (loop-tested)

Each line maps to one assertion in `verify.sh`. Done = one recorded **zero → success run**: empty project → `./deploy.sh` → `./verify.sh` all pass.

### A. One click
- [ ] A1. `./deploy.sh` exits 0 from an empty project; only prerequisite is a logged-in `gcloud` (script fails fast otherwise).
- [ ] A2. Second `./deploy.sh` run exits 0 and creates no duplicates (idempotent).
- [ ] A3. `./destroy.sh` exits 0 and leaves zero instances, disks, routers/NAT, firewall rules, VPC created by us.

### B. Ghost works
- [ ] B1. Public URL returns HTTP 200 with Ghost markup.
- [ ] B2. `<url>/ghost/` (admin) returns 200.
- [ ] B3. Containers (`ghost`, `mysql`, `cloudflared`) running and come back after `sudo reboot`; B1 passes again after reboot.

### C. No public SSH, tunnels only
- [ ] C1. VM has no external IP.
- [ ] C2. Only ingress rule in our VPC = tcp:22 from `35.235.240.0/20` (IAP).
- [ ] C3. No firewall rule in the whole project allows tcp:22 or tcp:3389 from `0.0.0.0/0` (default network's `default-allow-ssh` / `default-allow-rdp` removed).
- [ ] C4. `gcloud compute ssh --tunnel-through-iap` runs a command on the VM successfully.
- [ ] C5. Web traffic is served by `cloudflared` (outbound tunnel); egress works via Cloud NAT.

## Quality requirements (required, not loop-tested)

### D. Resource sizing — calibrate after DoD
- [ ] Start at `e2-small` (2 vCPU burst, 2 GB): Ghost's documented minimum is 1 GB RAM, plus MySQL 8.
- [ ] MySQL tuned for small RAM (`innodb_buffer_pool_size`, `performance_schema=OFF`); swap file as OOM safety net.
- [ ] Measure `free -m` / `docker stats` idle and under a short load test → record numbers and keep/resize decision.

### E. Fees (cost control)
- [ ] Monthly cost estimate per component (VM, disk, Cloud NAT) in this README.
- [ ] Billing budget alert on the project (low cap, e.g. €10).
- [ ] After the final run, `destroy.sh` leaves nothing billable (or a deliberate decision to keep the demo up, with its cost).

### F. Public repo hygiene — no secrets
- [ ] No keys, passwords, tokens, or service-account JSON in the repo or git history.
- [ ] DB passwords generated on the VM at deploy time, never echoed, never committed.
- [ ] `.gitignore` covers `.env`, key files, state files.
- [ ] `gitleaks` scan of full history passes before every push.
- [ ] AI conversation exports redacted (email/tokens) before commit.

### G. Documentation & traceability
- [ ] Architecture diagram, usage, prerequisites, trade-offs, out-of-scope list.
- [ ] Verification section with real outputs from the zero → success run.
- [ ] Time tracking end time filled in.
- [ ] AI conversations exported into `ai-conversations/` as the last step.

## Verification

_Filled with real evidence after the run._

## AI usage

Full AI conversation exports: [ai-conversations/](ai-conversations/).
