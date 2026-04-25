# ride-the-substrate — read the host before you defend it

Loaded by the router whenever a `defend.*` step is pending or `bl observe substrate` has emitted a substrate report. Companion to `defense-synthesis/`: the synthesis skills know rule grammar; this bundle knows whether the rule grammar applies to *this host*. The curator reads SKILL.md, picks the matching per-category file, then falls through to the synthesis skill that authors the directive.

## Why this bundle exists

The defense-synthesis skills assume a substrate, and the substrate is not constant: Apache+mod_security2 on cPanel, nginx+php-fpm on Debian 12, LiteSpeed under DirectAdmin — three different defensive vocabularies. A `SecRule` valid against the first will not load against the second and may load but mis-time on the third. The substrate is also rarely what the package list claims — two firewall backends installed does not mean two are active; `mod_security` in `rpm -ql` does not mean `SecRuleEngine On` is set in the vhost being defended; `journalctl` on PATH does not mean the journal carries the window the case needs. *Installed* and *active* are different states; the second is the one that matters.

## Files in this bundle

- `enumeration-before-action.md` — spine. Load on every `defend.*` turn.
- `apache-vs-nginx-vs-litespeed.md` — webserver determines WAF surface. Load when webserver != Apache or `defend modsec` pending.
- `firewall-backend-divergence.md` — six backends, one intent. Load when `defend firewall` pending.
- `journal-vs-syslog-vs-files.md` — log-substrate divergence. Load when any `bl observe log` verb pending.
- `package-integrity-as-baseline.md` — `rpm -V` / `dpkg --verify` as the cheapest tamper detector. Load when building a system-wide tampering hypothesis.

## Failure mode this bundle prevents

A `<SecRule>` authored against a host running nginx+naxsi. Grammar check passes, operator approves, apply succeeds (no Apache config to break), and the rule is operationally absent because no engine reads it. `bl observe substrate` would have flagged `webserver=nginx, modsec=absent`; the router would have loaded `apache-vs-nginx-vs-litespeed.md` ahead of `defense-synthesis/modsec-patterns.md`; the mismatch surfaces before the rule is authored.

## Cross-references

`defense-synthesis/modsec-patterns.md`, `defense-synthesis/firewall-rules.md`, `defense-synthesis/sig-injection.md` — grammars this bundle gates. `hosting-stack/cpanel-anatomy.md`, `hosting-stack/cloudlinux-cagefs-quirks.md` — layouts the substrate read surfaces.

<!-- public-source authored — extend with operator-specific addenda below -->
