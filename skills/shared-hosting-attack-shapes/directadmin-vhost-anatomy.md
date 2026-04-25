# shared-hosting — DirectAdmin compromise-shape (per-domain docroots and reseller hierarchy)

Loaded by the router when `shared_hosting_layer = directadmin`. DirectAdmin (DA) hosts a non-trivial slice of low-margin shared hosting — European fleets, SMB resellers, white-label hosting. No DA-specific layout file exists in the project; this file grounds the rules and defers to `docs.directadmin.com`.

A `maldet` hit lands on a DA host. The curator emits `bl observe htaccess /home/<user>/public_html/`. Path does not exist. DA's docroot is `/home/<user>/domains/<domain>/public_html/`. The authored step fails before reasoning lands. A second wrinkle: the operator suspends the user — FTP and email blocked — but Apache continues serving the docroot. The backdoor is still web-reachable hours after "user suspended" is filed.

Authoritative references: DA per-user filesystem layout (`docs.directadmin.com/directadmin/`), reseller and user management (`docs.directadmin.com/directadmin/customer-features/`), Apache `AllowOverride` (`https://httpd.apache.org/docs/current/mod/core.html`).

## Per-domain docroots

Each DA user can host multiple domains. Layout under `/home/<user>/`:

- `domains/<domain>/public_html/` — primary docroot. Tenant-writable.
- `domains/<domain>/private_html/` — non-served sibling. Apache does not serve directly; tenant-writable; intended for SSL-only or staging content per DA docs.
- `domains/<domain>/stats/` — per-domain Webalizer / AWStats output.
- `domains/<domain>/logs/` — per-domain logs.
- `.htpasswd/<domain>/` — per-domain `.htaccess` auth files.

`ls /home/<user>/domains/` enumerates every domain that user owns. A curator's first observe step on a DA host should run this to enumerate scope before any per-domain walk.

## `private_html/` as a staging spot — DA's `~/.cache/` equivalent

`private_html/` is the DA equivalent of cPanel's `~/.cache/` and Plesk's `private/`. DA documents it as the HTTPS-with-separate-content directory; common use today is "non-served sibling." A loader dropped there is reachable via `include('/home/<user>/domains/<domain>/private_html/loader.php')` from a `public_html/`-based dropper but never served as a URL.

```
find /home/<user>/domains/<domain>/private_html -type f \
  \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' \) \
  -newer /tmp/window.flag -printf '%TY-%Tm-%Td %m %u:%g %p\n'
```

Any PHP file under `private_html/` warrants a content read. Legitimate use is rare on modern installs.

## Reseller hierarchy and AllowOverride propagation

DA's hierarchy is `admin → reseller → user`. The reseller controls per-user package settings including the `AllowOverride` value applied to child users. `AllowOverride All` allows every child's `.htaccess` to inject `Options +ExecCGI`, `AddHandler`, `php_value`; `None` blocks them at the package level.

Per-user config tree:

- `/usr/local/directadmin/data/users/<user>/user.conf` — per-user limits, package, reseller assignment.
- `/usr/local/directadmin/data/users/<user>/domains.list` — domains owned.
- `/usr/local/directadmin/data/users/<user>/domains/<domain>.conf` — per-domain config.

A `.htaccess` injection investigation must read the reseller's `AllowOverride` before scoring impact. The same directive that works on user A under R1 may have no effect on user B under R2.

## Suspended user — the docroot keeps serving

The non-obvious DA rule that distinguishes it from cPanel/Plesk for IR: **a suspended DA user's `public_html/` is still served by Apache.** Suspension blocks FTP/SSH/email/panel access; the Apache vhost continues to serve `/home/<user>/domains/<domain>/public_html/` because suspension is a user-account state, not an Apache vhost state. Per `docs.directadmin.com/directadmin/customer-features/`, suspending a user disables their tools; content cleanup requires a manual docroot wipe or explicit "Unsuspend → Delete" sequencing.

"I suspended the user, the backdoor is contained" fails on DA. The backdoor remains web-reachable until the docroot is wiped or the vhost taken offline. DA-aware containment:

1. Suspend the user (blocks user-side access).
2. Move or wipe `domains/<domain>/public_html/` and `private_html/`.
3. Audit cron under `/etc/cron.d/` and `/var/spool/cron/<user>` — suspension does not stop scheduled cron.

See [`homedir-perms-traps.md`](homedir-perms-traps.md); [`../linux-forensics/persistence.md`](../linux-forensics/persistence.md) for cron survivors.

<!-- public-source authored — extend with operator-specific addenda below -->
