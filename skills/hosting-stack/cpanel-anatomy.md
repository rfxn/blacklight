# hosting-stack — cPanel layout for forensic context

Loaded by the router when the host stack is identified as cPanel-managed shared hosting. The case engine and intent reconstructor key on tenant-vs-system distinctions to attribute compromise correctly: a webshell in `/home/<user>/public_html/` is a tenant-scoped finding; the same shell pattern under `/usr/local/cpanel/` is a system-level breach with very different blast radius. This file is the layout reference that lets that distinction land cleanly.

## Document roots and tenant filesystem

Each cPanel account is a Linux user with `$HOME` at `/home/<user>/` (or `/home2/<user>/`, `/home3/<user>/` etc. on multi-disk layouts). The default web document root is `/home/<user>/public_html/`, which is also typically a symlink to `/home/<user>/www/`. Addon domains and subdomains live under `/home/<user>/<domain>/` or `/home/<user>/public_html/<subdir>/` depending on how they were created.

Per-account filesystem subtree:

- `/home/<user>/public_html/` — primary docroot. Tenant-writable.
- `/home/<user>/mail/<domain>/<localpart>/` — Maildir storage for that account's mailboxes. Format is the standard Maildir `cur/`, `new/`, `tmp/`.
- `/home/<user>/etc/<domain>/` — per-domain mail config (passwd, shadow for mailbox accounts, quota).
- `/home/<user>/logs/` — per-user log archive of rotated bytes_log files.
- `/home/<user>/.cpanel/` — per-user cPanel state. `nvdata/` holds API token records, custom contact info, and various preferences. A new `.cpanel/api_tokens_v2/` entry is a load-bearing finding (account API access established).
- `/home/<user>/.htpasswds/` — per-directory password files for `.htaccess`-protected paths.
- `/home/<user>/ssl/` — account-managed SSL artifacts.
- `/home/<user>/tmp/` — per-user tmp.
- `/home/<user>/.trash/` — files moved via the cPanel File Manager "trash" feature.

Tenant attacker reach: full read/write inside `/home/<user>/`, plus what their PHP processes can reach under suEXEC or PHP-FPM (the per-user pool runs as the user). The tenant cannot write to `/etc/`, `/usr/`, `/var/cpanel/`, or other accounts' `/home/` subtrees.

## EasyApache profile detection

EasyApache 4 (EA4) is the current Apache/PHP stack manager. The version installed and its configuration:

- `/etc/cpanel/ea4/` — EA4 profile and config root.
- `/etc/cpanel/ea4/profiles/` — saved profiles (JSON). The active profile is referenced by `current` symlink or the most recent timestamped file.
- `/etc/cpanel/ea4/php.conf` — global PHP handler config.
- `/var/cpanel/userdata/<user>/<domain>` — per-domain Apache vhost generation source (YAML). Edited via UAPI; the rendered Apache config is regenerated from these.
- `/etc/apache2/conf/httpd.conf` — generated, not hand-edited. Hand edits are wiped on the next `httpd --restart` triggered by `whmapi1`.
- `/etc/apache2/conf.d/userdata/<user>/<domain>/` — drop-in directory for per-domain custom config that survives regeneration.

PHP version per account is recorded in `/var/cpanel/userdata/<user>/<domain>` under the `phpversion` key, with options like `ea-php74`, `ea-php82`. Multiple PHP versions can coexist on the same server; an account can use a PHP version different from the system default.

## Execution context — suEXEC, CGI, PHP-FPM, mod_ruid2

The user that PHP code executes as is the load-bearing question for tenant-vs-system distinction.

- **suEXEC + suPHP / CGI** — historical default. PHP runs as the account user via the suEXEC wrapper. Process owner in `ps` is `<user>`, not `nobody` or `apache`. File writes by the PHP process land with `<user>:<user>` ownership.
- **PHP-FPM (per-user pool)** — current default in modern cPanel. Each account has its own `pool.d/` config under `/etc/php-fpm.d/<user>__<domain>.conf` (path varies by EA4 version). The pool's `user` and `group` directives name the account user.
- **mod_ruid2** — module that switches the Apache worker's UID per request based on the docroot's owner. Process owner in `ps` shows `apache` or `nobody` between requests but switches to `<user>` while the request is being processed.
- **DSO** (mod_php run as the Apache user) — historical, mostly removed from modern cPanel installs. Process owner is `nobody` or `apache`; file writes by PHP land with that ownership. Tenant attribution is harder under DSO because all tenants' PHP runs as the same UID.

For triage: read the file ownership of dropped files. Files owned by `<user>:<user>` point to that tenant's account being the entry. Files owned by `apache:apache` or `nobody:nogroup` point to a shared-UID handler and a broader investigation scope.

## .htaccess inheritance and security policies

Apache reads `.htaccess` files from the docroot down to the requested resource, applying directives cumulatively. cPanel imposes some `AllowOverride` restrictions through global config, but `Options`, `RewriteRule`, `php_value`, and most other directives are typically permitted in tenant `.htaccess`.

Tenant abuse vectors via `.htaccess`:

- `php_value auto_prepend_file /home/<user>/.cache/loader.php` — load attacker code on every request, even after the visible dropper is deleted.
- `RewriteRule ^(.+)\.(jpg|png|gif)$ $1.php [L]` — route image requests to PHP, defeating "block .php uploads" controls.
- `AddHandler application/x-httpd-php .jpg .png` — register PHP handler for image extensions.
- `Options +ExecCGI` plus `AddHandler cgi-script .pl .py` — enable CGI execution where it was off.

Triage: read every `.htaccess` in the suspect docroot, recursively. The `find <docroot> -name .htaccess -exec stat -c '%Y %n' {} +` lists them with mtime; sort by recency to spot recently-modified ones.

## /usr/local/cpanel/ — the cPanel system tree

System-side cPanel binaries, scripts, and runtime state.

- `/usr/local/cpanel/bin/` — internal binaries.
- `/usr/local/cpanel/scripts/` — operator-facing scripts (`scripts/restartsrv_httpd`, `scripts/securetmp`, etc.).
- `/usr/local/cpanel/whostmgr/` — WHM (server admin) interface code.
- `/usr/local/cpanel/Cpanel/` — Perl module tree (cPanel is largely Perl).
- `/usr/local/cpanel/3rdparty/` — bundled third-party software (php, perl modules, etc.).
- `/usr/local/cpanel/logs/` — system-side logs:
  - `access_log` — WHM/cPanel UI access log.
  - `error_log` — Perl runtime errors from cPanel processes.
  - `login_log` — every login attempt against cPanel/WHM/Webmail.
  - `cphulkd.log` — brute-force protection daemon log.
  - `incoming_mail_log`, `cpanel-dovecot-solr/`, etc. — service-specific.

A modification to anything under `/usr/local/cpanel/` is a system-level finding — tenants cannot reach this tree, so a write here means root or a privilege-escalation path.

## /var/log/cpanel/ and related log paths

Logs at the OS level relevant to cPanel forensics:

- `/var/log/cpanel-install/` — installation and update logs.
- `/var/log/cpanel/` — runtime logs.
- `/usr/local/cpanel/logs/access_log` — WHM/cPanel UI activity.
- `/var/log/exim_mainlog`, `/var/log/exim_rejectlog`, `/var/log/exim_paniclog` — Exim mail logs (cPanel's default MTA).
- `/var/log/maillog` — system mail log.
- `/var/log/secure` (RHEL-family) or `/var/log/auth.log` (Debian-family) — sshd, sudo, su.
- `/var/log/messages` — general system log.
- `/var/log/chkservd.log` — cPanel's service monitor.

Tenant-side log paths surviving a tenant filesystem wipe:

- `/var/log/apache2/` and `/etc/apache2/logs/` — Apache log root. Per-domain logs under `domlogs/<domain>` and `domlogs/<domain>-bytes_log`.
- The bytes_log format includes the bytes-served field that domlogs format strips; useful for sizing exfiltration.

If a customer wipes their `/home/<user>/` content during cleanup, the Apache logs at `/etc/apache2/logs/domlogs/<domain>` survive — the access record is intact even after the dropper is gone.

## /etc/cpanel/ and /var/cpanel/ — runtime state

`/etc/cpanel/` holds configuration; `/var/cpanel/` holds runtime state and per-user metadata.

- `/var/cpanel/users/<user>` — per-account metadata file (plan, IP, domains, suspended-state, plan limits).
- `/var/cpanel/userdata/<user>/<domain>` — per-domain webserver config source.
- `/var/cpanel/suspended/<user>` — presence of this file marks the account as suspended; cPanel's vhost generator emits a suspended-page vhost instead of the normal one. Cleanup workflow: `whmapi1 suspendacct user=<user>`.
- `/var/cpanel/bandwidth/usage/<user>/` — per-account bandwidth accounting.
- `/var/cpanel/sessions/` — active cPanel/WHM/Webmail sessions. Reading these reveals current logged-in tenants.
- `/var/cpanel/cpses_*` — internal cPanel session-related state.

Tenant suspension propagation: writing the marker file is one step; the next `httpd` restart picks up the suspended-page vhost. Until then, the live vhost continues to serve. For containment during active incident response, the operator pattern is `whmapi1 suspendacct user=<user>` followed by `service httpd restart` (or the EA4 graceful equivalent).

## Per-user resource limits — CloudLinux LVE

Many cPanel deployments run on CloudLinux, which adds the LVE (Lightweight Virtual Environment) layer. LVE imposes per-user CPU, memory, IO, and process count limits using kernel cgroups. Relevant for forensics:

- `/var/lve/users/<UID>/` — per-user LVE state.
- `lveinfo` and `lvetop` — observe live per-user resource use. A tenant whose webshell is mining cryptocurrency shows up here as 100% of their CPU quota sustained.
- `/var/log/lve-stats/` — historical LVE stats.

LVE faults (a tenant exceeding their limits) appear in `/var/log/messages` with `lve_enter` and related tags. A burst of LVE faults around a suspect window corroborates "this account was running something heavy".

## MySQL per-user grants and cpses_*

cPanel provisions MySQL users on a per-account basis. The naming convention is `<user>_<dbuser>` for both the database and the MySQL user — the `<user>_` prefix prevents collision across accounts.

- `mysql.user` table holds the MySQL user list. Grep for entries not matching the `<user>_` prefix on a multi-tenant box; those are operator-level credentials.
- `mysql.db` table holds the per-database grant matrix.
- `/var/cpanel/databases/users.db` — cPanel's mapping of MySQL users to cPanel accounts.

For Magento specifically, the `app/etc/env.php` file holds the DB credentials. A tenant compromise typically produces a `SHOW VARIABLES` or `SELECT @@hostname` query in the MySQL general log if it was on; a CloudLinux DB-governor log entry if MySQL Governor is active.

## Exim mail queue layout

cPanel ships Exim as the MTA. Mail-related triage paths:

- `/var/spool/exim/input/` — queued messages awaiting delivery. Each message is two files: `<msgid>-D` (data, the message body) and `<msgid>-H` (envelope, headers).
- `/var/spool/exim/msglog/` — per-message delivery log.
- `/var/log/exim_mainlog` — all delivery attempts.
- `/var/log/exim_rejectlog` — rejected by ACL.
- `/var/log/exim_paniclog` — Exim's own internal errors. Empty file is the expected steady state.

A tenant compromise that uses the host for spam relay produces a queue spike. `exim -bpc` (count of queued messages) trending upward sharply, plus `/var/log/exim_mainlog` filled with `<= ` (received) entries from `cwd=/home/<user>/...` paths, attributes the queue back to the tenant.

## What survives a customer-side wipe

A tenant who deletes their `/home/<user>/` content as a "cleanup" cannot reach:

- `/var/log/` in any form — Apache logs, Exim logs, syslog.
- `/usr/local/cpanel/logs/` — cPanel UI activity and login records.
- `/var/cpanel/` — the operator-level account metadata and audit records.
- Other accounts under `/home/`.

A tenant CAN destroy:

- The dropper files in their docroot.
- Their own `~/.bash_history`, `~/.mysql_history`, `~/.lesshst`.
- Maildir contents (mailboxes).

For incident response, the durable evidence is in the system-side log tree, not in the tenant's filesystem. Triage that opens with "the tenant deleted everything" is still answerable from `/var/log/apache2/domlogs/<domain>`, `/var/log/exim_mainlog`, and the cPanel access logs.

## Tenant-vs-system attribution checklist

When a finding lands, classify it before reasoning further:

- **Path under `/home/<user>/`** → tenant-scoped. Blast radius is that account.
- **Path under `/usr/local/cpanel/`** → system. Blast radius is the whole server.
- **Path under `/etc/`** → system. Same.
- **Path under `/var/cpanel/`** → system. Same.
- **File ownership `<user>:<user>`** → written by that account's PHP/CGI/SSH process.
- **File ownership `root:root` outside a package-owned location** → written by a root-equivalent process; investigate privilege path immediately.
- **File ownership `apache:apache` or `nobody:nogroup`** → DSO-mode PHP or web server itself wrote it; tenant attribution requires correlating with vhost access logs.

This classification belongs in the case-engine evidence row; the intent reconstructor and synthesizer treat tenant findings and system findings differently downstream.

<!-- public-source authored — extend with operator-specific addenda below -->
