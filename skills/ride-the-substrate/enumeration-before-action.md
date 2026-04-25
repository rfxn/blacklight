# enumeration-before-action — read the substrate first, every case

Loaded alongside `SKILL.md` whenever any `defend.*` step is pending or the curator's hypothesis turns on a time-windowed log read. The spine of this bundle: the substrate read precedes evidence reasoning, not the other way around. Every defensive verb in `bl` is conditional on what the host runs; every wrong assumption costs an apply-and-rollback cycle the operator has to clean up by hand.

## The 04:27 problem

It is 04:27 local on an unknown customer host. The trigger is a maldet hit. The temptation: open the dropper, reason about its capability, propose a `defend modsec` step blocking the URL pattern that delivered it. The move is wrong, because nothing has answered the load-bearing question — *which Apache binary is on PATH*? `/usr/sbin/httpd` (RHEL), `/usr/sbin/apache2` (Debian), `/opt/cpanel/ea-apache24/sbin/httpd` (cPanel EA4), or none (host is a thin reverse proxy; WAF lives upstream). The case is not "what does the dropper do." The case is "what defense vocabulary does *this* host actually understand," and only after that is settled does evidence reasoning produce a `defend.*` step that can land. Same shape for firewall, logs, scanner, integrity tooling, and hosting layer.

## Three rules that bind every turn

**1. Substrate enumeration is the first action of every case, not the second.** A common analyst error is to read evidence first and substrate second, because evidence is what the maldet hit named. The vocabulary in which evidence is summarized depends on the substrate — Apache combined log shape differs from nginx default differs from LiteSpeed — and a `finding` summary in the wrong vocabulary forces every subsequent revision to translate. Run `bl observe substrate` as the first turn after `bl case --new`, and route on its output.

**2. "Installed" is not "active."** A package present (`rpm -q mod_security`, `dpkg -l mod-security2`) does not mean a request hits a `SecRule` evaluator. Active membership must be observed:

- `apachectl -M | grep security2` confirms the module is loaded into running Apache, not just installed on disk. Upstream Apache documentation on `httpd -M`: `https://httpd.apache.org/docs/2.4/programs/httpd.html`.
- `grep -rE '^\s*SecRuleEngine\s+(On|DetectionOnly|Off)' /etc/httpd /etc/apache2` enumerates every engine-state directive. A single `SecRuleEngine Off` in a vhost overrides the global `On` for that vhost only.
- `apachectl configtest` confirms the config parses but says nothing about which directive wins per vhost.

The same gap applies to firewall (installed APF + active firewalld), logs (`journalctl` on PATH but `Storage=volatile`), and scanners (LMD installed but cron disabled). Every category needs the second observation.

**3. The substrate read is a tier-0 input.** Read-only — no kernel state mutates, no rule loads, no service restarts. Its absence forces every downstream decision into guesswork. Never gate it behind a confirmation prompt; never skip it because "we ran it last week"; never defer it on the grounds that the maldet hit feels urgent. Two minutes upfront buys the operator hours of unwound rollback later.

## The verification pattern, in one shape

Three steps, every category: *is it installed* (`rpm -q`, `dpkg -l`, `command -v`); *is it active* (`apachectl -M`, `nft list ruleset`, `systemctl is-active`, `journalctl --disk-usage`); *what does it carry* (the `SecRuleEngine` directive in a loaded conf, the rule count in the live nftables ruleset, the `Storage=` line in `journald.conf`). Downstream files drill into per-category specifics; this file fixes the pattern.

## Failure mode named

A curator emits `defend modsec` against a host where `mod_security2` is `LoadModule`-ed globally but `SecRuleEngine Off` is set in the vhost the curator did not read. `apachectl configtest` passes. `bl-apply` symlinks the rule and restarts Apache cleanly. The case ledger records the rule deployed; the operator believes the host is defended; protection is silently absent for the vhost the original maldet hit fired against. Failure is visible only in the *absence* of the expected ModSec audit log entry.

The pattern prevents the path: the substrate report's `modsec.engine_state.per_vhost` field carries one record per vhost; reading it surfaces the `Off` override; the synthesis turn pivots — either the rule lands at a higher-precedence config layer (per `hosting-stack/cpanel-anatomy.md` §EasyApache profile detection), or the curator flags the engine-state mismatch to the operator as an open question before any rule is authored.

## Cross-references

- `apache-vs-nginx-vs-litespeed.md`, `firewall-backend-divergence.md`, `journal-vs-syslog-vs-files.md` — sisters; same installed-vs-active pattern for webserver, firewall, and log categories.
- `defense-synthesis/modsec-patterns.md` — downstream; the rule grammar this skill gates.
- `hosting-stack/cpanel-anatomy.md` — cPanel changes the Apache binary path and vhost-include layout.

<!-- public-source authored — extend with operator-specific addenda below -->
