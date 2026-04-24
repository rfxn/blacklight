<!-- writer: wrapper, when: on-evidence-ingest (when a new block-hit record ingests for an applied action), lifecycle: append-only, cap: 30 KB, src: case-layout.md §3 row 16, tier: docs/action-tiers.md §2 -->

# Defense hits

<!-- Wrapper appends one row per block-hit event for actions in `actions/applied/`. Tier column maps to docs/action-tiers.md §2 enum. -->

| Timestamp (ISO-8601) | Act-id | Tier | Hit source | Hit count (window) | Notes |
|----------------------|--------|------|------------|--------------------|-------|
<!-- WRAPPER-APPEND -->
