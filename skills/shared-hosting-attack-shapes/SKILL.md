# shared-hosting-attack-shapes — bundle router

Loaded when the substrate-report names `shared_hosting_layer != none`. The pitch's named adopter class is hosting providers and MSPs; their fleets are mostly cPanel, Plesk, and DirectAdmin. Compromise *shapes* on those three layers diverge enough that loading the wrong layer file produces correct-shaped reasoning against the wrong layout — a curator emits `bl observe htaccess /home/<user>/public_html/` against a Plesk host where that path does not exist, and the case stalls. This bundle is the lookup of which layer file to load and what each layer's compromise tells are.

## What this bundle covers

Three layer-specific files plus a perms-trap consolidation. Each layer file is *compromise-shape*, not layout-only — backdoor staging spots, panel-managed config that stomps hand-edits, suspended-account states where the docroot still serves. cPanel layout reference is sibling [`../hosting-stack/cpanel-anatomy.md`](../hosting-stack/cpanel-anatomy.md); CloudLinux additions in [`../hosting-stack/cloudlinux-cagefs-quirks.md`](../hosting-stack/cloudlinux-cagefs-quirks.md). The new files are sibling-angle, not duplicates — read the layout file for the path map, then the compromise-shape file for the IR-relevant tells.

## Routing

```
IF substrate-report shared_hosting_layer = cpanel
  → load cpanel-vhost-anatomy.md
  AND ../hosting-stack/cpanel-anatomy.md (layout reference)
  AND IF /var/cagefs/ or /var/lve/ present
    → ALSO load ../hosting-stack/cloudlinux-cagefs-quirks.md

IF substrate-report shared_hosting_layer = plesk
  → load plesk-vhost-anatomy.md
  AND ../defense-synthesis/modsec-patterns.md (panel-managed modsec interaction)

IF substrate-report shared_hosting_layer = directadmin
  → load directadmin-vhost-anatomy.md

IF curator is reasoning about file-permission evidence on any host with shared_hosting_layer != none
  → ALWAYS load homedir-perms-traps.md alongside the layer file
```

## Why a separate axis

Shared-hosting layer is an axis on top of OS, web server, and firewall — not derivable from any of those. Two hosts with identical Rocky 9 + Apache 2.4 + APF posture diverge sharply if one runs cPanel and the other runs Plesk: docroot path, per-domain Apache include chain, modsec rule-injection site, suspended-tenant behavior, and customer-side cleanup blast radius are all different. Skipping this axis is the most common reason a curator's first-pass observe steps misfire on shared-hosting fleets.

Where no layout file exists (Plesk, DirectAdmin), the compromise-shape file carries enough layout to ground the rule and defers to vendor docs (`docs.plesk.com`, `docs.directadmin.com`) cited inline.

<!-- public-source authored — extend with operator-specific addenda below -->
