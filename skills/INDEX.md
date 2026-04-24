# blacklight skills router

Domain knowledge lives as files. The curator loads this router on every turn
per `prompts/curator-agent.md §3 Read-first ordering`, then selects only the
skill files whose signals match the evidence shape arriving this turn — 1M
context is generous but not free, and injection pressure grows linearly with
loaded skill surface. This file answers one question at each branch: *given
the signals present in this evidence, which skill files add useful context
for the curator reasoning now?*

Files cite one another via `see skills/<path> §Section` pointers (per the M3
dedup lattice). Routing here respects that lattice — when two files are
mutually bound, the router loads the authority side and the pointer pulls
the complement in at read time.

---

## On every curator turn

Always load, regardless of signal. Minimum set; cheap; universally useful.

- `ir-playbook/case-lifecycle.md` — status transitions, support types, confidence discipline, capability map, anti-patterns. The spine of every hypothesis revision.
- `ir-playbook/kill-chain-reconstruction.md` — five-stage MITRE-mapped narrative (T1190 → T1505.003 → T1027 → T1071.001 → T1053.003) with stage evidence requirements.

---

## Route by observable signal

### When the stack includes Magento

```
IF stack includes Magento 2.x → load magento-attacks/admin-paths.md
                                 AND magento-attacks/writable-paths.md
  AND IF Adobe advisory patch window matches suspicious mtime cluster
    → ALSO load apsb25-94/exploit-chain.md AND apsb25-94/indicators.md
  AND IF a persistent admin/API-level foothold is suspected
    → ALSO load magento-attacks/admin-backdoor.md
```

### When a PHP shell drop is suspected

```
IF PHP files found outside typical framework paths
  → load webshell-families/polyshell.md (load-bearing family reference)
  AND webshell-families/minimal-eval.md (single-liner variants)
  AND IF obfuscation layers require decoding
    → ALSO load obfuscation/base64-chains.md AND obfuscation/gzinflate.md
```

### When synthesizing defenses

```
IF generating ModSec rules
  → load defense-synthesis/modsec-patterns.md (idioms + anchor patterns)
  AND modsec-grammar/rules-101.md (grammar floor — authoritative)
  AND IF evasion signals present (transformation-laden payload, double-encoding, base64 body)
    → ALSO load modsec-grammar/transformation-cookbook.md
IF generating firewall rules
  → load defense-synthesis/firewall-rules.md (backend semantics + CDN safelist)
  AND apf-grammar/basics.md (when target is APF)
  AND IF C2 callback IOCs in scope
    → ALSO load apf-grammar/deny-patterns.md
IF synthesizing a file signature (YARA / LMD / ClamAV)
  → load defense-synthesis/sig-injection.md (scanner detection + FP gate + naming)
  AND ioc-aggregation/file-pattern-extraction.md (feature selection)
```

### When analyzing log evidence

```
IF apache access logs are primary evidence
  → load linux-forensics/apache-transfer-log.md
  AND IF POST→shell-fire correlation is under question
    → ALSO load linux-forensics/post-to-shell-correlation.md
IF ModSec audit logs are evidence
  → load linux-forensics/modsec-audit-format.md
  AND IF visibility-gap analysis needed
    → cross-read with linux-forensics/post-to-shell-correlation.md §Audit-log-vs-transfer-log
IF LMD session logs / hits.hist are evidence
  → load linux-forensics/maldet-session-log.md
```

### When reconstructing attribution

```
IF multi-IP cluster present
  → load ioc-aggregation/ip-clustering.md (behavioral clustering by feature)
  AND actor-attribution/timing-fingerprint.md (beacon cadence + intra-session jitter)
IF operator role-typing is needed
  → load actor-attribution/role-taxonomy.md (six canonical roles — load FIRST)
IF campaign vs opportunistic classification
  → load actor-attribution/campaign-vs-opportunistic.md
```

### When building a timeline

```
IF ordering events across multiple sources
  → load timeline/event-extraction.md (per-format parsing + dedup)
  AND timeline/interval-segmentation.md (I1/I2/I3 phase markers)
```

### When suspicious persistence indicators appear

```
IF cron / systemd / rc.local / ld.so.preload / shell-init modified in recent window
  → load linux-forensics/persistence.md
IF suspicious outbound callbacks in access.log or auth.log
  → load linux-forensics/net-patterns.md
```

### When scope spans hosting infrastructure

```
IF compromise topology spans multiple hosts on shared platform
  → load hosting-stack/cpanel-anatomy.md
  AND IF CloudLinux indicators present (/var/cagefs/, /var/lve/)
    → ALSO load hosting-stack/cloudlinux-cagefs-quirks.md
```

### When false-positive triage is needed

```
IF flagged file is inside a known-benign vendor tree
  → load false-positives/vendor-tree-allowlist.md
IF flagged file is an ionCube / SourceGuardian / Zend Guard encoded bundle
  → load false-positives/encoded-vendor-bundles.md
IF flagged artifact matches backup tooling conventions (rsnapshot/rdiff/tar.gz/sqldump)
  → load false-positives/backup-artifact-patterns.md
```

### When extracting URL / file IOC patterns

```
IF generalizing N URL strings into one ModSec rule
  → load ioc-aggregation/url-pattern-extraction.md
IF generalizing N file fingerprints into one YARA rule
  → load ioc-aggregation/file-pattern-extraction.md
  AND defense-synthesis/sig-injection.md (for promotion discipline)
```

### When closing a case with a brief

```
Always load for format consistency:
- ic-brief-format/template.md (brief shape, section ordering)
- ic-brief-format/severity-vocab.md (P0–P4 ladder, downgrade triggers, notification matrix)
- ic-brief-format/ioc-categorization.md (8-category mandatory IOC order)
- ic-brief-format/executive-summary-voice.md (§1 voice discipline, forbidden constructions)
```

### When remediation choreography is in scope

```
IF post-defense cleanup ordering matters
  → load remediation/cleanup-choreography.md (backup → quarantine → remove → audit order)
```

---

## Operator-voice core

Files carrying the operator's domain voice (no ghostwriting). These are the
load-bearing credibility surface; any bundle-depth reduction that cuts these
is the wrong cut.

- `ir-playbook/case-lifecycle.md` — reasoning spine
- `ir-playbook/kill-chain-reconstruction.md` — chain narrative
- `webshell-families/polyshell.md` — family reference
- `defense-synthesis/modsec-patterns.md` — rule idioms
- `defense-synthesis/firewall-rules.md` — firewall discipline
- `defense-synthesis/sig-injection.md` — signature discipline
- `false-positives/` (catalogue)
- `hosting-stack/` (shared-tenant platform quirks)
- `ic-brief-format/` (brief conventions)
- `ioc-aggregation/` (feature-based pattern extraction)
- `remediation/cleanup-choreography.md` — cleanup ordering

The rest — `apsb25-94/`, `modsec-grammar/`, `apf-grammar/`, `magento-attacks/`,
`linux-forensics/`, `obfuscation/`, `timeline/`, `actor-attribution/` (and
`webshell-families/minimal-eval.md`) — are scaffolded from public advisory /
MITRE / Sansec / OWASP / upstream documentation.

---

## Bundle depth

42 skill files across 16 subtrees. Depth over breadth — every file satisfies
`DESIGN.md §9.2` (scenario-first opening, non-obvious rule, public-source
example, named failure mode). No slop; `TODO(gap):` markers flag
tribal-knowledge requirements rather than ship boilerplate.

Attribution: operator-authored (Ryan MacDonald). Public-source adaptations
are marked with `<!-- adapted from ... -->` trailers; the sister-project
beacon (2026-04-23) is one such source.
