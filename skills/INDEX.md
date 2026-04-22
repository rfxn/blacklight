# blacklight skills router

Decision-tree routing per [CrossBeam's pattern](https://github.com/mikeOnBreeze/cc-crossbeam)
— domain knowledge lives as files; routing loads the relevant subset per call rather
than stuffing the whole bundle into context. This file is itself loaded on every
major curator call.

The router answers one question at each branch: *given the signals present in this
evidence, which skills files add useful context for the agent about to reason?*

---

## On every case-engine revision call
Always load, regardless of other signals:

- `ir-playbook/case-lifecycle.md` — when to revise, split, merge, hold. Confidence
  thresholds. The spine of hypothesis revision.

## On every synthesizer call
Always load:

- `defense-synthesis/modsec-patterns.md` — validated rule shapes for ModSec
- `modsec-grammar/rules-101.md` (when generating ModSec) OR
  `apf-grammar/basics.md` (when generating APF) — the grammar reference for
  the defense class being generated

## When analyzing a host (triage + hunters)
Route by observable signal:

```
IF stack includes Magento 2.x → load magento-attacks/admin-paths.md
  AND IF Adobe advisory patched AFTER earliest suspicious mtime
    → load apsb25-94/indicators.md
IF PHP files found outside typical framework paths
  → load webshell-families/polyshell.md
IF suspicious outbound callbacks in access.log or auth.log
  → load linux-forensics/net-patterns.md
IF cron / systemd units / shell-init / ld.so.preload modified in recent window
  → load linux-forensics/persistence.md
IF file flagged but path is inside a known-benign vendor tree
  → load false-positives/
IF compromise topology spans multiple hosts on a shared platform
  → load hosting-stack/cpanel-anatomy.md
```

## When producing operator-facing briefs
Load for format consistency with the team's existing IR voice:

- `ic-brief-format/template.md` — brief shape, severity vocabulary, artifact
  conventions, IOC block format

---

## Bundle ownership

Six operator-authored core files carry the domain voice (no ghostwriting):

- `ir-playbook/case-lifecycle.md`
- `webshell-families/polyshell.md`
- `defense-synthesis/modsec-patterns.md`
- `false-positives/` (catalog)
- `hosting-stack/` (shared-tenant quirks)
- `ic-brief-format/` (brief conventions)

The rest (`apsb25-94/`, `modsec-grammar/`, `apf-grammar/`, `magento-attacks/`,
`linux-forensics/`) are scaffolded from public advisory and reference material.

Target bundle depth: ~20 files (vs CrossBeam's 28). Depth per file over file count.
