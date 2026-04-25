# apache-vs-nginx-vs-litespeed — webserver determines WAF surface

Loaded by the router when `bl observe substrate` reports webserver != Apache, or when the curator is about to author a `defend modsec` step. This file is the lookup of "given this web server, what is the actual `defend.*` menu I have." Pairs with `enumeration-before-action.md` (the why) and gates `defense-synthesis/modsec-patterns.md` (the rule grammar that only applies when ModSec is the engine).

## The misroute that triggers this skill

A POST-to-PHP from a single source IP fires a maldet hit. The curator's first instinct is to author a `SecRule` matching the request shape — the grammar `defense-synthesis/modsec-patterns.md` teaches. But the substrate report shows `nginx` fronting `php-fpm`, no ModSec module loaded, no Apache binary on the host. The synthesis grammar does not apply. The defense menu collapses to firewall-only, upstream-WAF-only, or naxsi/openappsec/modsecurity-nginx if any are installed — and "if any are installed" has to be read off the substrate, not assumed.

## Three rules that bind webserver-typed defense

**1. The web server determines the default WAF surface.**

- **Apache + `mod_security2`** — common on cPanel, Plesk, EA4-managed hosts. Rule authoring follows `defense-synthesis/modsec-patterns.md` directly. Validate with `apachectl configtest`. Presence: `apachectl -M | grep security2`. Engine state: `grep -rE '^\s*SecRuleEngine' /etc/httpd /etc/apache2`.
- **nginx** — typically *no* in-process WAF. Documented options: `ModSecurity-nginx` (libmodsecurity v3 connector, Apache grammar largely ports over — `https://github.com/owasp-modsecurity/ModSecurity-nginx`); `naxsi` (whitelist-grammar WAF — `https://github.com/wargio/naxsi`); `mod_evasive` (rate-limiting; nginx-equivalent is `ngx_http_limit_req_module` — `https://github.com/jzdziarski/mod_evasive`); `open-appsec` (`https://docs.openappsec.io/`). Each tool's documented purpose is named factually; this skill does not recommend pivoting between them — operator-domain.
- **LiteSpeed (LSWS / OpenLiteSpeed)** — common on cPanel and DirectAdmin fleets. Ships a built-in mod_security-compatible engine (see `https://docs.litespeedtech.com/lsws/cp/cpanel/`). Rule grammar parses; rule *timing* drifts — see Rule 3.
- **No webserver, or thin reverse proxy (HAProxy, Traefik, lightweight nginx)** — WAF lives upstream. Defense surface on *this* host collapses to firewall + signature scanning. Substrate flags `webserver.role=reverse_proxy`, and `defend modsec` is a no-op until the upstream host is in scope.

**2. Many "nginx fleet" defenses live on the Apache origin.** Operator-grade nginx deployments frequently use nginx as a thin reverse proxy and host the application — and the WAF — on an Apache origin behind it. The substrate report's `webserver.upstream_origin` field, when populated, redirects `defend modsec` to that upstream host. Surface the origin as the apply target; do not author against nginx the rule that "should have been" against the origin.

**3. LiteSpeed's mod_security parity is partial.** A rule that passes Apache's grammar may load on LiteSpeed but mis-match request phase. LSAPI request lifecycle: `https://docs.litespeedtech.com/lsws/lsapi/`; mod_security compatibility note: `https://docs.litespeedtech.com/lsws/cp/cpanel/`. Both confirm the points at which `REQUEST_HEADERS_RAW` and `ARGS_POST` are populated diverge from upstream Apache. A `phase:1` rule reading `REQUEST_URI` is portable; a `phase:2` rule reading `ARGS_POST` is not always portable. Substrate must flag `webserver.litespeed.phase_drift = WARN` so the synthesis skill restricts to phase-1 patterns or routes to a LiteSpeed-aware template.

LiteSpeed-specific notes: `apachectl configtest` does not exist — validation is `lswsctrl restart` plus a hand-check against the audit log to confirm the rule fired. Reload is `lswsctrl restart`, not `apachectl graceful`.

## Failure mode named

A curator authors an Apache-grammar `SecRule` against a LiteSpeed+CRS host where the rule's `phase:2` evaluation runs after the request body is already partially consumed. Rule loads. `lswsctrl restart` returns success. The rule does not match the IOC pattern because the phase-2 hook fires later in the LSAPI lifecycle than the Apache equivalent. The case ledger records "deployed cleanly," the operator believes the host is defended, and the next request matching the IOC pattern still hits the webshell. Failure is visible only in the *absence* of the expected `defense-hits.md` entry — the same shape `enumeration-before-action.md` Rule 2 names ("installed is not active") in a different vocabulary.

Mitigation: when LiteSpeed is detected, flag `webserver.litespeed.phase_drift = WARN`. The synthesis skill either restricts to phase-1 patterns or surfaces the phase-drift risk to the operator as an open question before the rule is authored.

## Cross-references

- `enumeration-before-action.md` — bundle spine, webserver-specialized here.
- `defense-synthesis/modsec-patterns.md` — downstream rule grammar this skill gates.
- `hosting-stack/cpanel-anatomy.md` — cPanel + LiteSpeed binary paths.

<!-- public-source authored — extend with operator-specific addenda below -->
