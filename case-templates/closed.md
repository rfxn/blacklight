<!-- writer: wrapper, when: on-close, lifecycle: present-iff-closed, cap: 20 KB, src: case-layout.md §3 row 17 + §5 -->
---
case_id: {CASE_ID}
closed_at: {ISO_8601_TIMESTAMP}
brief_file_id_md: {FILE_ID_OR_EMPTY}
brief_file_id_pdf: {FILE_ID_OR_EMPTY}
brief_file_id_html: {FILE_ID_OR_EMPTY}
retirement_schedule:
  - act_id: {ACT_ID}
    retire_when: {ISO_DATE_OR_CONDITION}
    reason: {PROSE}
---

# Closed case: {CASE_ID}

## Summary

<!-- wrapper renders from hypothesis.md final revision + operator closure note -->

## Retirement schedule

<!-- wrapper renders table from retirement_schedule[] frontmatter; mirrors actions/applied/<act-id>.yaml retire_hint field per case-layout.md §9 -->

## Ledger pointer

<!-- wrapper writes: /var/lib/bl/ledger/{CASE_ID}.jsonl — authoritative post-memstore-expiry per case-layout.md §10 -->
