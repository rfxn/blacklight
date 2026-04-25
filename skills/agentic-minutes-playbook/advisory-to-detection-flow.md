# agentic-minutes-playbook — advisory to detection flow

Loaded alongside `pre-alert-deployment.md` when `bl consult --sweep-mode --cve <id>` opens or when the curator's hypothesis turns on a fresh advisory cite. Walks the six stages from public advisory to a queued `defend.*` step.

---

## The lived flow — APSB25-94, T+0:00 to T+2:45

Adobe publishes APSB25-94 at 10:00 EDT on 2025-10-14. By 12:45 EDT a detection package is queued in `bl-case/CASE-<id>/actions/pending/`, FP-gated, paired with a one-command rollback. Six stages:

| Stage | Window | Curator emits | Wrapper validates |
|-------|--------|---------------|-------------------|
| 1. Read advisory | T+0:00–0:15 | URL + summary anchored on Adobe's "Affected versions" / "Solution" tables | Substrate read — fleet hosts vulnerable software, on what server? |
| 2. Identify IOC class | T+0:15–0:30 | One of the six classes below | Class slug in `hypothesis.md` routes to emit grammar |
| 3. Author candidate | T+0:30–1:30 | `defend.modsec` / `defend.firewall` / `defend.sig` body per `defense-synthesis/*.md` | Syntax: `apachectl configtest`, YARA sandbox parse, ASN safelist |
| 4. FP-gate vs benign corpus | T+1:30–2:00 | Rule + corpus invocation | Corpus floor (≥1000 PHP); zero matches |
| 5. Tier-gate per `docs/action-tiers.md` | T+2:00–2:15 | `action_tier` field | `defend.modsec` always `suggested`; `defend.firewall` `auto` only off-CDN; `defend.sig` `auto` only post-FP-pass |
| 6. Rollback envelope + queue | T+2:15–2:45 | `rollback:` field; action moved to `actions/pending/<id>.yaml` | Rollback parses, references a real verb, inverts the rule |

Each stage gates the next. A failed stage returns the action to draft with a structured reason; never auto-promotes despite failure.

---

## The IOC-class taxonomy

The load-bearing decision is the IOC class, not the rule body. Misclassifying APSB25-94 as a "user-agent string" advisory sends the curator down a useless path; the rule body is mechanical once the class is named.

- **path-pattern** — REQUEST_URI shape (`/rest/V1/<endpoint>`, `.php/<...>.jpg`). APSB25-94 is path-pattern; see `apsb25-94/exploit-chain.md §Initial access vector`. Emit: `SecRule REQUEST_URI` per `modsec-patterns.md §URL-evasion`.
- **header-field** — Host, Referer, User-Agent, custom header. Emit: `SecRule REQUEST_HEADERS:<name>`.
- **body-field** — POST body shape (JSON key, form field, multipart name). Emit: `SecRule REQUEST_BODY` or `ARGS_POST`.
- **file-magic** — first-N-byte fingerprint of dropped artifact. Emit: YARA per `sig-injection.md §Non-obvious rule`, two-axis condition mandatory.
- **network-callback** — outbound destination (TLD shape, ASN cluster). Emit: APF/iptables block per `firewall-rules.md`.
- **kill-chain-step** — sequence of two or more requests in a window (POST → GET). Emit: chained ModSec with `setvar`/`expirevar`.

If two classes apply, emit two rules. Hybrid rules collapse the FP-gate's diagnostic value when one axis fails.

---

## The FP-gate — load-bearing for advisory-driven emits

With alert-driven emits, the FP-gate answers "did the rule fire on the existing FP corpus." With advisory-driven emits, no local true-positive exists yet — the FP-gate is the only signal the rule is safe to deploy. Skipping it is the failure mode `pre-alert-deployment.md` exists to prevent.

The wrapper enforces it structurally: actions cannot promote from `actions/pending/` to `actions/applied/` without `fp_gate.status = pass`. Corpus floor (≥1000 benign PHP files) and seeding discipline come from `defense-synthesis/sig-injection.md §Corpus FP gate`. Same rule for ModSec — replay the host's last 24h access.log against an audit-only deployment and count would-have-blocked rows. Non-zero demotes `action_tier` to `suggested` with matching paths in `reasoning`.

---

## The rollback envelope is co-authored with the rule

A rule shipped without a known rollback owns the operator if it misfires. Every advisory-driven rule pairs with a single-command rollback at emit time, written into `actions/pending/<id>.yaml` `rollback`:

- ModSec rule `id:9100` → `bl defend modsec --remove 9100`
- Firewall block on `203.0.113.51` → `bl defend firewall --remove 203.0.113.51`
- YARA `BL_polyshell_loader_<date>_<hash>` → `bl defend sig --remove <name>`

The wrapper validates the rollback parses, names the same artifact installed, and uses a `bl` dispatcher verb. A rule with no parseable rollback is bounced back to draft.

---

## Failure mode

Curator authors a path-pattern ModSec rule for APSB25-94 without running stage 4. Rule fires on legitimate Magento checkout traffic; tenants' storefronts return 403; revenue hit. The wrapper's gate (`fp_gate.status` required for promotion) prevents this in normal operation. The override — `bl defend modsec --unsafe --yes` — writes a structured override entry to the ledger so the next-on-call sees what happened.

---

## Public-source grounding

- Adobe Security Bulletin APSB25-94 — `https://helpx.adobe.com/security/products/magento/apsb25-94.html`.
- `apsb25-94/exploit-chain.md` and `apsb25-94/indicators.md` — IOC class reconstructed from advisory + public post-advisory reporting.
- OWASP CRS docs — `https://coreruleset.org/docs/`.
- MITRE ATT&CK T1190 (`https://attack.mitre.org/techniques/T1190/`).

---

## Cross-references

`SKILL.md`, `pre-alert-deployment.md`, `apsb25-94/*`, `defense-synthesis/*`, Bundle 1's `enumeration-before-action.md`.

<!-- public-source authored — extend with operator-specific addenda below -->
