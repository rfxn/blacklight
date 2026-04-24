# Role Taxonomy — Six Behavioral Roles

**Source authority:** operator-voice distillation of public incident-response literature, cross-referenced with MITRE ATT&CK Enterprise matrix <https://attack.mitre.org/matrices/enterprise/> — in particular Initial Access (TA0001), Execution (TA0002), Persistence (TA0003), and Command and Control (TA0011). Secondary corroboration from Sansec SessionReaper research <https://sansec.io/research/sessionreaper-exploitation>, Infiniroot Magento incident writeups, and community IR postmortems covering PolyShell-era drops.

The taxonomy compresses the observable variance in a multi-IP incident into six roles. Every IP in a triaged incident should end up labeled with at least one of these roles; many IPs occupy two or three over time. The curator loads this skill before any other actor-attribution skill — the rest of the category uses these role names as fixed vocabulary.

---

## The six roles

### 1. Initial-intrusion actor

The IP that lands the original shell or achieves the first code-execution event.

- **Canonical signal:** one-shot POST with a 200 response to the vulnerable endpoint (`/custom_options/` for APSB25-94, `/customer/address_file/upload` for APSB25-88 post-deserialization), followed by silence from that IP.
- **Session length:** seconds to a few minutes. Often a single request.
- **Return behavior:** rarely returns. The write has been done; the initial-intrusion actor hands off to other roles.
- **Diagnostic:** if the same IP comes back repeatedly, it is probably not purely initial-intrusion — relabel as initial-intrusion + reconnaissance or + C2.

### 2. Reconnaissance actor

Post-compromise enumeration against a shell that already exists.

- **Canonical signal:** short bursts of commands that look like textbook host enumeration — `uname -a`, `id`, `whoami`, `ls -la /`, `cat /etc/passwd`, `cat /etc/shadow`, `ifconfig`, `netstat -an`.
- **Session length:** minutes to an hour. Typical 5 to 20 shell hits.
- **Return behavior:** may or may not return; recon is often a one-pass survey.
- **Diagnostic:** command set matches the "first things run after getting a shell" playbook. No file writes, no long-running processes, no secondary tooling uploads.

### 3. C2 operator

Sustained interactive use of the shell.

- **Canonical signal:** polling-pattern traffic (see `timing-fingerprint.md`), typically GET or POST requests at regular intervals — 10 seconds to several minutes — over hours or days.
- **Session length:** hours to weeks. Many hundreds of requests.
- **Return behavior:** returns continuously; this is the "hands-on-keyboard" or "tool-in-the-loop" role.
- **Diagnostic:** upload of secondary tooling (additional PHP scripts, compiled binaries, PHP eval libraries); long sessions; repeated access to the same set of files.

### 4. Htaccess-delete / persistence-layer actor

Writes the persistence layer — `.htaccess` edits, `accesson.php` sprays, admin-user insertions, `cron_schedule` hijacks, `app/etc/env.php` or `local.xml` edits.

- **Canonical signal:** file writes that are **not** the shell itself. `.htaccess` under `pub/media/`, PHP drops under `app/etc/` or `app/code/`, SQL insertions into `admin_user`.
- **Session length:** minutes. Focused, procedural.
- **Return behavior:** may return later to verify persistence survives.
- **Diagnostic:** **often a different IP from the initial-intrusion actor.** This is the toolchain handoff — scanner teams compromise hosts, monetization teams build persistence. Do not assume initial-intrusion and persistence are the same operator just because both touched the shell.

### 5. Skimmer-layer actor

Post-compromise JS injection for payment-data exfiltration.

- **Canonical signal:** edits to checkout-page templates or JS bundles (`.phtml` with inline script tags, new `.js` files served from the site origin, `main.js` or `app.js` modifications with WebRTC DataChannel code).
- **Session length:** a single write session, typically minutes.
- **Return behavior:** often returns weeks later to rotate exfiltration infrastructure (C2 domain or WebRTC endpoint changes).
- **Diagnostic:** deploys **weeks after initial compromise**, once the shell is stable and monitoring has died down. The lag is itself diagnostic — fresh-drop skimmers are rarer than lagged-drop skimmers.

### 6. Cleanup actor

Attempts to erase evidence.

- **Canonical signal:** `rm -rf` against webshell or tooling paths, log-file truncation or deletion, `touch -r <adjacent-file> <target>` mtime stomping, history file deletion (`~/.bash_history`), audit log gaps.
- **Session length:** minutes. Fast and targeted.
- **Return behavior:** rare. Cleanup is usually a one-shot "before we leave" pass.
- **Diagnostic:** search for mtime anomalies (files with mtime that predates their install time by a suspicious margin), truncated log files (size 0 or abrupt end-of-day timestamps), and missing entries in logs that rotate to a central collector.

---

## Role-to-evidence matrix

| Role | Primary log signal | File-system signal | Timing signal |
|------|-------------------|---------------------|---------------|
| Initial-intrusion | Single POST 200 to vulnerable endpoint | New file under write-path (PolyShell in `pub/media/`) | One request, then silence |
| Reconnaissance | GET to shell with recon-command query | No writes | Short burst, no return |
| C2 operator | Sustained poll pattern to shell | Secondary tool uploads | Regular-interval polling (see `timing-fingerprint.md`) |
| Persistence | POST writes to `.htaccess`, `app/etc/`, `admin_user` inserts | `.htaccess` mtime change, `accesson.php` spray | Brief, procedural session |
| Skimmer | Edits to checkout template / JS bundle | New or modified `.js` at site origin | Lagged; weeks after initial |
| Cleanup | DELETE or POST with `rm` arguments | mtime anomalies, truncated logs | One-shot, late in timeline |

Cross-reference this matrix with [`../linux-forensics/post-to-shell-correlation.md`](../linux-forensics/post-to-shell-correlation.md) for the per-HTTP-status interpretation rules used to spot each role.

---

## Role-transition rules

A single IP can — and routinely does — occupy multiple roles across the incident timeline. Time-segmentation by role transition produces the interval markers that downstream timeline analysis consumes.

**Common transitions:**

1. Initial-intrusion → reconnaissance (same IP). The adversary confirms the shell works by immediately enumerating. Many opportunistic actors never move past this point.
2. Reconnaissance → C2 operator (same IP). The operator decides the host is worth holding and switches to sustained polling.
3. C2 operator → persistence (often **different IP**). Toolchain handoff. The first actor sells or passes access to a team that builds the monetization path.
4. Persistence → skimmer (often different IP, lagged by weeks). Skimmer-deployer is a downstream monetization role; by this point initial-intrusion and C2 operators have moved on.
5. Any role → cleanup (often same IP as whichever role last held the shell). Cleanup fires when the adversary notices detection pressure.

**Time-segmentation rule:** when assigning roles, cut the IP's timeline at gaps larger than 10× the median inter-request delta (same heuristic used in `timing-fingerprint.md` for session boundaries). Each segment gets an independent role label. A single IP that is "recon for 10 minutes on Monday, C2 for three days starting Wednesday, cleanup for one minute on Friday" is three roles, not one confused one.

---

## Failure modes

**Labeling every IP that touches the shell "C2".** Mass scanners that hit an already-dropped shell to confirm its presence are **reconnaissance**, not C2. Distinguish by session length and command repetition — C2 operators return many times over hours or days; recon scanners hit once or twice and leave. If 50 IPs hit the shell exactly once each across a week, none of them are C2 — they are recon (or noise).

**Treating all persistence writes as coming from the same actor as the initial drop.** The toolchain handoff between scanner teams and monetization teams is a documented pattern in the Sansec research. Initial-intrusion IPs and persistence IPs routinely differ. Label them separately and let clustering (see `../ioc-aggregation/ip-clustering.md`) decide whether they belong to the same campaign.

**Assigning roles before timelining.** Roles are time-scoped. A role assignment for "IP X across the whole incident" hides the transitions. Always segment first, label second.

---

## Triage checklist

- [ ] List every distinct IP observed in the incident window
- [ ] For each IP: collect HTTP request count, first-seen timestamp, last-seen timestamp, set of URLs touched
- [ ] Segment each IP's timeline at gaps > 10× median inter-request delta
- [ ] Assign one role per segment using the role-to-evidence matrix
- [ ] Flag IPs that occupy persistence or skimmer roles for cross-CVE correlation — load [`campaign-vs-opportunistic.md`](campaign-vs-opportunistic.md)
- [ ] Flag IPs with sustained polling for timing-pattern analysis — load [`timing-fingerprint.md`](timing-fingerprint.md)
- [ ] Cluster IPs with aligned role + behavior — load [`../ioc-aggregation/ip-clustering.md`](../ioc-aggregation/ip-clustering.md)
- [ ] Document the role-transition timeline per IP (I1/I2/I3-style interval markers for downstream timeline analysis)

---

## See also

- [../ioc-aggregation/ip-clustering.md](../ioc-aggregation/ip-clustering.md) — how to group role-labeled IPs into actors
- [timing-fingerprint.md](timing-fingerprint.md) — timing signals that refine the C2-operator role assignment
- [campaign-vs-opportunistic.md](campaign-vs-opportunistic.md) — campaign classification once roles are assigned
- [../linux-forensics/post-to-shell-correlation.md](../linux-forensics/post-to-shell-correlation.md) — per-HTTP-status rules used to spot each role

<!-- adapted from beacon/skills/actor-attribution/role-taxonomy.md (2026-04-23) — v2-reconciled -->
