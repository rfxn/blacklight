# host-3 — clean nginx storefront (empty-by-design)

This directory is intentionally empty. host-3 is the fleet's Nginx-fronted
storefront with no on-disk compromise indicators and no access-log evidence
relevant to the APSB25-94 PolyShell campaign. Per `EXPECTED.md` §host-3, the
day-2 hunter dispatch does not target host-3 and no findings are expected.

## Why an empty directory rather than a deleted host

The fleet topology is a load-bearing fixture for the case-split scenario in
`EXPECTED.md` (host-5 skimmer family resolves as `support_type=unrelated`
across hosts 2/4/7 — the unrelated-host count anchors the calibrated
confidence rise from 0.6 → 0.85). Removing host-3 would understate the
fleet's clean baseline. The empty directory is the assertion: present in
roster, zero findings expected.

## Synthesis stance

No staging script needed. Any future regeneration that fills this host with
synthetic traffic should preserve the zero-attack-finding invariant — only
RFC 5737 `192.0.2.0/24` (TEST-NET-1) source addresses, only legitimate
storefront paths, no `.cache/`, `.bin/`, or `.tmp/` PHP artifacts.

## Cross-references

- `exhibits/fleet-01/EXPECTED.md` §host-3 — the negative-assertion contract.
- `exhibits/fleet-01/README.md` — fleet roster + correlation chain.
