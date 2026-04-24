# case-templates/ — contract manifest

`M5` (`bl_case_new`, wave-2) reads this file to determine which templates to materialize on `bl case --new`. Every entry here binds to a row of `docs/case-layout.md` §3 writer-owner table.

## 1. On-open-seed manifest

Materialized on `bl case --new` into `bl-case/CASE-<YYYY>-<NNNN>/` (except `INDEX.md` which is workspace-wide — wrapper appends a row to the existing roster instead of copying into the case subtree).

| Filename | Writer | When | Cap | case-layout.md §3 row |
|----------|--------|------|-----|-----------------------|
| `hypothesis.md` | curator | on-open + on-hypothesis-revision | 50 KB | §3 row 2 |
| `open-questions.md` | curator | on-hypothesis-revision | 15 KB | §3 row 10 |
| `attribution.md` | curator | on-hypothesis-revision | 40 KB | §3 row 6 |
| `ip-clusters.md` | curator | on-evidence-ingest | 30 KB | §3 row 7 |
| `url-patterns.md` | curator | on-evidence-ingest | 20 KB | §3 row 8 |
| `file-patterns.md` | curator | on-evidence-ingest | 20 KB | §3 row 9 |
| `defense-hits.md` | wrapper | on-evidence-ingest | 30 KB | §3 row 16 |
| `INDEX.md` | wrapper | on-open + on-close | 100 KB (workspace-wide) | §3 row 1 |

## 2. Schema-only file (NOT on-open-seeded)

| Filename | Writer | When | Cap | Reason not on-open |
|----------|--------|------|-----|--------------------|
| `closed.md` | wrapper | on-close | 20 KB | case-layout.md §3 lifecycle `present-iff-closed` — materializing on open violates the lifecycle invariant; wrapper renders from this template on `bl case close` |

## 3. Post-materialize validation

After `bl_case_new` writes the 7 per-case seeds + the INDEX roster row, M5 runs this grep to confirm the writer-owner metadata is intact. Expected exit: `0` on success; any file listed is a MUST-FIX.

```bash
grep -L 'writer: \(curator\|wrapper\)' \
  bl-case/CASE-*/{hypothesis,open-questions,attribution,ip-clusters,url-patterns,file-patterns,defense-hits}.md \
  | wc -l
# expect: 0
```

## 4. Change control

Additions to `docs/case-layout.md` §3 writer-owner table (new paths) require a matching entry in this manifest **in the same commit**. Reviewer flags missing targets as MUST-FIX (per `docs/case-layout.md` §11).

<!-- writer: M2-spec, when: on-authoring, lifecycle: immutable-after-commit, cap: 8 KB -->
