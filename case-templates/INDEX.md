<!-- writer: wrapper, when: on-open + on-close, lifecycle: append-mostly, cap: 100 KB workspace-wide, src: case-layout.md §3 row 1 + §6 -->

# bl-case workspace index

Workspace roster. One line per case. Wrapper-maintained per `docs/case-layout.md` §6.

The trailing `Fingerprint` column carries `trigger_fingerprint` (16-hex) so
`bl consult --new --dedup` can resolve duplicates from a single GET against
this INDEX instead of fanning out one GET per active case's hypothesis.md.

| Case | Opened | Status | Hypothesis (30-char preview) | Closed brief (file_id) | Fingerprint |
|------|--------|--------|------------------------------|-------------------------|-------------|
<!-- WRAPPER-APPEND -->
