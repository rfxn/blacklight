# demo-fixture-spec — exhibit envelope + layout

Authoritative contract for the PolyShell (APSB25-94) demo fixture: what shape it takes, how it reproduces cleanly in a public OSS repo, and how it hands evidence to `bl observe` / `bl consult` during the 3-minute recording. Companion to `schemas/evidence-envelope.md` (record contract) and `DESIGN.md §10` (bundle shape). Supersedes the ad-hoc `exhibits/fleet-01/*.php` pattern where scanner-safety or reproducibility conflict.

---

## 1. Envelope decision

**Hybrid directory tree + on-demand staging.** Not a tarball. Not a docker-compose-only fixture. Not a raw-PHP tree.

- The **tree** is what ships in the git repo. It contains narrative (`.md`), record data (`.jsonl`), indicator lists (`.yaml`), and pattern fragments in code-fenced markdown. It is scanner-safe by construction — no executable PHP at any path GitHub's code-scanner indexes.
- The **staging layer** is generated at demo time by `stage.sh` from the tree. It materialises the filesystem layout `bl observe` walks (including `.htaccess`, `a.php-sample.txt`, cron excerpts, ModSec rules) into a scratch directory under `/var/tmp/bl-demo-<ts>/`. Never committed, `.gitignore`'d, cleaned up by the script on exit.
- A **docker-compose** layer is optional and lives inside the staging output — `stage.sh --with-container` stands up Apache + mod_security against the staged tree for the "live traffic" beat. Operators without Docker can still run the REPL demo against the staged filesystem alone.

### Why this envelope

Three alternatives were rejected:

| Option | Rejection reason |
|---|---|
| **Tarball committed to repo** (`fleet-01.tgz`) | Opaque to judges cold-reading the repo; GitHub's scanner does unpack small archives, so scanner-safety advantage is modest; operator audit of fixture content requires manual extract. |
| **Pure docker-compose** (image builds fixture at up-time) | Adds a hard Docker dependency to the demo path. Judges who clone and `ls exhibits/` see nothing. The architectural point that "the fixture reconstructs from public APSB25-94" is invisible. |
| **Raw `.php` tree** (current `host-2/a.php` shape, pre-rewrite) | GitHub's secret/code scanners flag `eval(` and `base64_decode(` regardless of `// dormant` comment headers. A public repo under `rfxn/blacklight` with flagged PHP under `exhibits/` generates scanner noise for every operator fork and degrades the repo's signal-to-ceremony ratio. |

The hybrid resolves all three: tree is audit-legible, staging is reproducible, container is optional.

### What survives from existing `exhibits/fleet-01/`

- The **scenario taxonomy** (`host-1-anticipatory`, `host-2-polyshell`, `host-3-nginx-clean`, `host-4-polyshell-second`, `host-5-skimmer`, `host-7-polyshell-third`) is preserved. The ground-truth sheet at `exhibits/fleet-01/EXPECTED.md` is preserved.
- The **dormant-capability comment pattern** from the prior `a.php` / `skimmer.php` is preserved verbatim (it IS the convention; see §4).
- The **`.php` files themselves** are rewritten to `.php-sample.txt` with the dormant-capability comment block intact (see §4.1 migration). `exhibit.md` carries the narrative.

---

## 2. Tree layout

Every exhibit sits under `exhibits/fleet-01/<scenario>/` with this layout:

```
exhibits/fleet-01/
├── README.md                               # operator's guide — what to run, what to expect
├── EXPECTED.md                             # ground-truth sheet (pre-existing, preserved)
├── indicators.yaml                         # fixture-global IOC set, public-advisory-only
│
├── host-1-anticipatory/                    # clean Magento storefront; anticipatory 920099 fires
│   ├── exhibit.md                          # narrative + dormant-capability commentary
│   ├── logs/
│   │   └── apache-transfer.jsonl           # fabricated access log, envelope-conforming
│   ├── fs/
│   │   └── (empty — no on-disk compromise)
│   └── filesystem-layout.md                # mtime+perm map for bl observe fs --mtime-since
│
├── host-2-polyshell/                       # PolyShell v1auth variant (canonical)
│   ├── exhibit.md                          # narrative + attack-chain walkthrough
│   ├── samples/
│   │   └── a.php-sample.txt                # dormant-capability commented shell (see §4)
│   ├── logs/
│   │   ├── apache-transfer.jsonl
│   │   ├── apache-error.jsonl
│   │   └── modsec-audit.jsonl
│   ├── fs/
│   │   ├── htaccess.txt                    # injected .htaccess rendering (text, not runtime)
│   │   └── cron-wwwdata.txt                # ANSI-obscured crontab line (cat -v form)
│   └── filesystem-layout.md
│
├── host-3-nginx-clean/                     # clean Nginx baseline; no findings expected
│   └── filesystem-layout.md
│
├── host-4-polyshell-second/                # second drop path, same family, same C2
│   └── (same subtree shape as host-2)
│
├── host-5-skimmer/                         # Magecart family; triggers case-split beat
│   └── (same subtree shape as host-2)
│
├── host-7-polyshell-third/                 # third drop path, third-host corroboration
│   └── (same subtree shape as host-2)
│
├── stage.sh                                # materialises the tree into a scratch fixture
├── stage-env.sh                            # env vars the staging script honors
└── .gitignore                              # excludes any stage/ output if produced in-tree
```

### File-type rules (scanner-safe invariants)

| Extension | Purpose | Rule |
|---|---|---|
| `.md` | narrative, attack-chain, commentary | Any PHP/JS fragment MUST be inside a ``` ```php ``` / ``` ```js ``` fenced block; MUST be preceded by a `> EXHIBIT — NOT EXECUTED` admonition; MUST be obfuscation-stripped (no `eval(`, no `base64_decode(` on an actual payload string — use `<...elided...>` placeholder). |
| `.txt` | webshell samples, htaccess renderings, cron renderings | NOT a language-recognised extension. Content uses full dormant-capability comment pattern (§4). GitHub's linguist classifies as plain text; code-scanner does not parse. |
| `.jsonl` | fabricated evidence records | Every line MUST validate against `schemas/evidence-envelope.md`. No commentary lines, no BOM, `\n`-terminated, one record per line. |
| `.yaml` | indicator lists, fixture-global IOC sets | Public-advisory-only content (IPs from `203.0.113.0/24` test-net, hostnames from `.example` / `.test`, rule IDs from APSB25-94 public advisory). |
| `.sh` | staging scripts | Only `stage.sh` and `stage-env.sh`. Must be `shellcheck`-clean, must not `eval` any string from a `.txt` or `.md`. |

**Prohibited in the committed tree:**

- `.php`, `.phtml`, `.inc` — even with dormant comments, scanner-noisy.
- `.html` containing `<script>` with actual skimmer payload (even commented).
- Archive files (`.tgz`, `.tar.gz`, `.zip`) containing any of the above.
- Any file whose SHA-256 matches a known-malicious hash from a public malware corpus (we reconstruct shapes, not bytes).

### `indicators.yaml` — single source of truth for fixture IOCs

```yaml
version: 1
cve: APSB25-94
advisory_url: https://helpx.adobe.com/security/products/magento/apsb25-94.html
ip_ranges:
  scanner:
    - 203.0.113.51              # TEST-NET-3 (RFC 5737)
    - 203.0.113.62
    - 203.0.113.71
hostnames:
  c2_polyshell: vagqea4wrlkdg.top   # pattern-accurate non-resolvable placeholder
  c2_skimmer:   skimmer-c2.example  # .example (RFC 2606)
rule_ids:
  anticipatory_cred_harvest: "920099"   # fabricated sequence; matches no upstream CRS rule
file_paths:
  polyshell_drops:
    - pub/media/catalog/product/.cache/a.php
    - pub/media/catalog/product/cache/.bin/a.php
    - pub/media/import/.tmp/a.php
  skimmer_drops:
    - pub/media/catalog/product/.cache/skimmer.php
sha256_hashes:
  polyshell_v1auth: fabricated-NOT-REAL-0000000000000000000000000000000000000000000000000000000000000000
  skimmer_magecart: fabricated-NOT-REAL-1111111111111111111111111111111111111111111111111111111111111111
```

IPs use TEST-NET-3 (`203.0.113.0/24`, RFC 5737). Hostnames use `.example` / `.test` / non-resolvable placeholders (no real C2 domains, even dead ones). SHA-256 strings are placeholder-prefixed so no accidental collision with a real corpus entry.

---

## 3. Public-advisory reconstructibility

Every artifact in the tree MUST be reproducible from the public APSB25-94 advisory alone. Operator-local material (the `~/admin/work/proj/depot/polyshell/` case files, `/home/sigforge/var/ioc/polyshell_out/` CSVs) is a shape-check only — NEVER a source of bytes, strings, hostnames, IPs, or paths in the committed fixture.

### Reconstructibility test

A fixture artifact passes the test if a third-party security engineer, given only:
1. The Adobe APSB25-94 public advisory page,
2. The public ModSec CRS rule grammar,
3. Public Magento 2.4.x docs,
4. This spec (`docs/demo-fixture-spec.md`),

…can rebuild a shape-equivalent artifact without access to this repo's git history or any operator-local material. If the artifact requires operator-local data to reproduce, it does not belong in the committed fixture.

### Data-fence grep (enforcement)

The fixture build pipeline (CI lane, future) runs this grep against the committed tree on every commit. Any hit fails the build:

```
# Operator-local identifiers — never committed
cloudhost-
nxcli.net
lb1.
sigforge
/home/sigforge/

# Real customer-path markers observed in operator data
cpanel.<tenant>
<real-customer-tld>
```

Specific match strings live in `.rdf/fixture-scrub-denylist.txt` (operator-private; enforced by CI but the denylist itself is not public). Contributors without the denylist get a weaker pass — the scrub is a defense-in-depth, not a primary guarantee; the primary guarantee is authorship discipline.

---

## 4. Dormant-capability comment pattern

This is the convention established by the pre-pivot `exhibits/fleet-01/host-2/a.php` and `host-5/skimmer.php`. It is preserved verbatim for new exhibits; only the file extension migrates (`.php` → `.php-sample.txt`).

### 4.1 Shape

Every sample file opens with:

```
# staged exhibit — APSB25-94 public advisory reconstruction — NOT customer data
# <family> variant typical of PolyShell post-APSB25-94:
#   outer: <obfuscation layer N description>
#   inner: <obfuscation layer N-1 description>
# The inner payload is NON-FUNCTIONAL by design: it echoes a sentinel string
# (BL-STAGE <sample-id>) for each dispatched key but never invokes
# system(), exec(), passthru(), or eval() against user input.
# Do NOT arm this file.
#
# dormant-capability markers (commented for exhibit; DO NOT execute or uncomment):
#   - cmd exec     : <how live variants dispatch command execution>
#   - file r/w     : <how live variants read/write files>
#   - callback     : <C2 callback pattern; uses fabricated non-resolvable host>
#   - persistence  : <persistence pattern — htaccess, cron, etc.>
```

Followed by the pattern-accurate but **commented-out** reconstruction. `.php-sample.txt` means the file is text to every parser; the PHP-shaped fragments inside are lines starting with `#` or `//` — no interpreter will run them; GitHub's code-scanner tokenises plain text not `eval()`.

### 4.2 Migration from existing `.php`

Current `host-2/a.php` and equivalents rewrite to `host-2/samples/a.php-sample.txt` with:

- Header comment block retained (no changes to text).
- Executable PHP lines (`$_0x=chr(98)...`, `$_p=$_0o($_0x($_q))`, `eval($_p);`) commented out (`# ` prefix) or replaced with `<...elided — see exhibit.md for the shape...>` placeholder.
- The accompanying `exhibit.md` carries a **non-executable** narrative description of the shape, inside a fenced block, with an `> EXHIBIT — NOT EXECUTED` admonition.
- The file at the old `.php` path is removed in the same commit as the new `.txt` is added — no dual-maintenance.

Migration is a discrete commit step ordered after this spec lands; it is not performed here.

### 4.3 Sentinel strings

Every sample carries a `BL-STAGE <sample-id>` string somewhere in its commented body. The staging script greps for this sentinel to confirm the file is a staged exhibit, not something an operator accidentally dropped under `exhibits/`. A sample file without the sentinel is rejected at stage time.

---

## 5. Staging semantics (`stage.sh`)

`stage.sh` is the operator's single entry point to materialise the fixture into a scratch fs for `bl observe` to walk.

```
Usage: stage.sh [--scenario <host-N-name>] [--scratch <dir>] [--with-container] [--clean]

  --scenario     One of host-1-anticipatory / host-2-polyshell / host-3-nginx-clean
                 / host-4-polyshell-second / host-5-skimmer / host-7-polyshell-third.
                 Default: host-2-polyshell (the canonical demo scenario).
  --scratch      Scratch directory. Default: /var/tmp/bl-demo-<timestamp>/.
  --with-container
                 Additionally start the optional Apache + mod_security container
                 that fronts the staged filesystem. Requires docker-compose v2.
  --clean        Remove the scratch directory and exit. No staging, no container.
```

### 5.1 What staging does

1. Creates `<scratch>/fs/` from the scenario's `fs/` tree — preserves `filesystem-layout.md` mtimes and perms.
2. Copies each `samples/*-sample.txt` into `<scratch>/fs/<path-from-layout>` with the rename `*-sample.txt` → `*.php` (so `bl observe fs` and `bl observe htaccess` find them at the path the fabricated logs reference). These copies live ONLY in the scratch dir; they are never written back into the repo.
3. Copies `logs/*.jsonl` into `<scratch>/logs/` unchanged (records are already envelope-conforming).
4. Writes `<scratch>/stage-manifest.json` — records scenario, scratch path, mtime policy, commit hash, sample-id sentinels found.
5. If `--with-container`, emits `<scratch>/docker-compose.yml` and `docker compose up -d`s it.

### 5.2 What staging does NOT do

- Does not network. Does not call `anthropic.com`. Does not create a case. Staging is strictly local filesystem materialisation.
- Does not execute any `.php` it writes. The extensions change because `bl observe` needs real filenames; the runtime never interprets them. If the operator does `apt install php && php <scratch>/fs/.../a.php`, that is on them; the repo ships no such invocation.
- Does not persist across boots. `/var/tmp/` is the default — survives session, wiped on reboot. Operators who want persistence can pass `--scratch /some/long-lived/path`.

### 5.3 Cleanup

`stage.sh --clean` removes the scratch directory. The demo-recording operator runs this between takes. `stage.sh` traps EXIT and attempts cleanup on abnormal exit; operators can override with `BL_STAGE_NO_CLEANUP=1` for debugging.

### 5.4 Host-side AV / scanner caveat

The staging step renames `*-sample.txt` → `*.php` inside `<scratch>/fs/`. Operators running host-side file scanners (ClamAV via `clamd`, LMD via `maldet --monitor`, tracker/Spotlight full-content indexing, enterprise EDR) will have those scanners walk the scratch directory and may match on the pattern-accurate (though non-functional) content and quarantine/alert/index it. During a live demo a host-AV quarantine event at the wrong moment destroys the recording take. Three mitigations, in preference order:

1. **Exclude the scratch path from host scanners before running the demo.** Default path is `/var/tmp/bl-demo-*/`. ClamAV: `ExcludePath` in `freshclam.conf`; LMD: add to `/usr/local/maldetect/conf.maldet` `ignore_paths`; EDR: vendor-specific.
2. **Run the demo on a dedicated VM / container with no host-side AV.** The demo does not need the host's scanner state — `bl observe sigs` reports on whatever scanners ARE installed; absence is data, not failure.
3. **Stage under `$XDG_CACHE_HOME/bl-demo/`** (operator-configurable via `--scratch`) if the operator's AV exclusion policy is easier to author for `~/.cache/` than for `/var/tmp/`. This is a preference, not a recommendation — the default stays `/var/tmp/` because that is what survives operator-home rotation during recordings.

The staging script prints a one-line reminder about AV exclusions on every invocation (suppressible with `BL_STAGE_QUIET=1`). This is cheap friction that saves a demo take.

---

## 6. Evidence-envelope conformance

Every `logs/*.jsonl` file in every scenario is validated against `schemas/evidence-envelope.md` at commit time (via a pre-commit hook once CI lands; until then, manually by the author). Specifically:

- Preamble fields (`ts`, `host`, `case`, `obs`, `source`, `record`) present on every line.
- `source` value in the closed taxonomy (§2 of evidence-envelope.md).
- `record` shape matches the declared per-source fields (§3 of evidence-envelope.md).
- No operator-local identifiers anywhere in the record.

A scenario whose logs fail this check does not ship. The wrapper's live emit path and the fixture's fabricated emit path share one contract — a fixture that drifts is a demo bug, not a wrapper bug.

---

## 7. What this spec does not cover

- **The `bl observe` emit path itself** — lives in the wrapper source + `schemas/evidence-envelope.md`.
- **The curator's handling of fixture records** — it does not distinguish fabricated from live; both go through the same fence and case workflow.
- **Fleet scale / multi-host fleets at scan time** — `exhibits/fleet-01/` has 6 hosts; larger fleet simulation is a P2 item in `PIVOT-v2.md §17`.
- **Non-APSB25-94 exhibits** — future CVEs get their own `exhibits/<advisory-id>/` subtree following the same envelope rules. `EXPECTED.md` per-advisory; no cross-exhibit coupling.

---

## 8. Open items (resolve before demo recording)

1. **Migrate existing committed `.php` exhibits to `*-sample.txt`** per §4.2. Complete list of paths to convert (from the current tree at the time this spec lands):
   - `exhibits/fleet-01/host-2-polyshell/a.php` → `exhibits/fleet-01/host-2-polyshell/samples/a.php-sample.txt`
   - `exhibits/fleet-01/host-4-polyshell-second/a.php` → `exhibits/fleet-01/host-4-polyshell-second/samples/a.php-sample.txt`
   - `exhibits/fleet-01/host-5-skimmer/skimmer.php` → `exhibits/fleet-01/host-5-skimmer/samples/skimmer.php-sample.txt`
   - `exhibits/fleet-01/host-7-polyshell-third/a.php` → `exhibits/fleet-01/host-7-polyshell-third/samples/a.php-sample.txt`
   Each migration is a three-step commit: (a) add the `*-sample.txt` with dormant-capability header preserved and executable PHP lines `#`-prefixed, (b) remove the old `.php`, (c) update `EXPECTED.md` path references. Commit separately from this spec; order-independent across the four files.
2. **Author `stage.sh`** and `stage-env.sh` — not in scope for this commit; spec-only for now.
3. **Author per-scenario `exhibit.md`** narratives for host-1 / host-3 / host-4 / host-7 (host-2 and host-5 have commentary in their existing `.php` headers that migrates verbatim).
4. **Populate `logs/*.jsonl`** for each scenario, envelope-conforming. `EXPECTED.md` lists the categories each scenario's hunters should surface — the fabricated logs ground-truth those categories. Validate against `schemas/evidence-envelope.md` at author time (no CI lane yet).
5. **Decide whether `--with-container` is a demo requirement or a nice-to-have** — recording time on Saturday is the deciding constraint. Default assumption: filesystem-only staging is enough for the 3-minute demo; the container path is a P2 polish item.
