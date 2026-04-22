# magento-attacks — admin surface and post-auth paths

Loaded by the router when the host stack includes Magento 2.x. Magento's admin surface, REST API, and module-loader conventions are the entry-and-pivot territory for the attack classes that show up in shared-hosting IR — credential brute force, post-auth extension upload, the APSB25-94 unauthenticated REST chain, and the writable-cache drop pattern. This file is the field reference for what each surface looks like in logs and on disk.

## Admin URL discovery

Magento 2 ships with a default admin path of `/admin`, but the install wizard prompts the operator to choose a custom value. The chosen path is stored in two places:

- `app/etc/env.php` — `'backend' => ['frontName' => '<path>']`. This is the source of truth at runtime.
- The `setup-config:set --backend-frontname=` value persisted at install time, mirrored into env.php.

Defaults and common operator values: `/admin`, `/admin_<random>`, `/backend`, `/manage`, `/dashboard`. Attacker enumeration probes the default first, then walks a wordlist; the access log shape is hundreds of `404` responses against single-word paths from one source IP within a tight window, all `GET /` against the candidate path.

Once the path is known, the login form sits at `/<frontName>/admin/auth/login` with the canonical full route `/index.php/<frontName>/admin/auth/login`. Both forms work because Magento accepts the rewritten and unrewritten variants.

## Admin user enumeration

Magento 2 returns identical error text for "user not found" and "wrong password" on the login form, which blocks naive enumeration through the UI. Two side channels remain:

- **Forgot-password endpoint** at `/<frontName>/admin/auth/forgotpassword`. Older Magento 2 versions (pre-2.4) returned distinguishable success/failure responses depending on whether the email was associated with an admin user. Adobe addressed the timing aspect across multiple advisories; check the installed version against the security release notes.
- **Direct database access** if the attacker has SQL injection or a stolen DB credential — the `admin_user` table holds usernames, email, and a bcrypt-hashed password.

In access.log, brute force shows up as repeated `POST /<frontName>/admin/auth/login` from one or a small set of IPs, response codes mostly `200` (the form renders with an error) interspersed with `302` on success. Valid-credential success is a single `POST` returning `302` to `/<frontName>/admin/admin/dashboard/`. The cookie set on success names `admin` in the cookie path: `Set-Cookie: admin=<sessionid>; path=/<frontName>/admin/`.

## REST API attack surface

Magento 2 exposes a REST API at `/rest/V1/`, `/rest/<store>/V1/`, and `/rest/all/V1/`. Endpoints are partitioned by authorization:

- **Anonymous** — `/rest/V1/products`, `/rest/V1/categories`, search and storefront read paths. Brute force, scraping, and enumeration noise.
- **Customer** — `/rest/V1/carts/mine`, `/rest/V1/customers/me`. Bearer-token auth via `/rest/V1/integration/customer/token`.
- **Admin** — `/rest/V1/customers`, `/rest/V1/products` (write), `/rest/V1/orders`. Bearer-token via `/rest/V1/integration/admin/token`.
- **Guest** — checkout-style endpoints accepting a quote ID, designed for not-yet-authenticated cart flows.

The unauthenticated-RCE pattern in advisory-class incidents is a `POST` to a REST endpoint that accepts a structured object, where the object's deserialization or downstream handler triggers code execution before the authorization layer rejects it. The access-log shape is short — one or two `POST /rest/V1/<endpoint>` requests with non-trivial body length, returning `200` or `500`, immediately followed by GET requests to a newly-created file in the document root.

For APSB25-94-class indicators (URL-evasion routing, payload class, post-exploitation file shapes), see `apsb25-94/indicators.md`. The Adobe security bulletin format is `https://helpx.adobe.com/security/products/magento/apsbXX-YY.html`; advisories list affected versions, severity, CVE assignments, and remediation versions.

## Extension and theme upload as RCE vector

The Magento admin "System → Web Setup Wizard → Extension Manager" and the legacy "Component Manager" interfaces both accept `.zip` uploads. An admin user, once authenticated, has full filesystem write access through these channels because module installation legitimately drops PHP files into `app/code/<Vendor>/<Module>/` and `vendor/<vendor>/<package>/`.

Indicator shapes:

- A `POST /<frontName>/admin/admin/system_config/save/` followed by file writes under `app/code/` or `vendor/` outside any composer-managed update window.
- New module directories whose `composer.json` lists no real upstream package or whose vendor name is a typo of a known vendor (`magneto/`, `magemto/`).
- Direct writes to `app/etc/config.php` adding a module entry (`'<Vendor>_<Module>' => 1`) without a corresponding composer change.

Extensions installed through Magento Marketplace go through `composer require` and leave a record in `composer.lock`. Out-of-band installs do not.

## Writable cache and media as drop paths

Magento's writable directories are the default landing zones for post-auth file drops because they are guaranteed writable by the web user.

- `pub/media/` — uploaded product images, customer uploads. Writable. Served by the web server. Subdirectories `pub/media/wysiwyg/`, `pub/media/catalog/product/`, `pub/media/.cache/` (some versions).
- `var/cache/` — runtime cache. Writable. Not normally served, but a rewrite rule or `.htaccess` flip can change that.
- `var/tmp/`, `var/log/`, `var/session/` — runtime working directories. Writable by the PHP process.
- `pub/static/` — generated static assets. Writable during deploy; a `.htaccess` permitting PHP execution here is anomalous.
- `generated/` — DI-generated PHP. Writable. PHP execution is expected here as part of normal Magento operation, which makes it a high-quality hiding ground.

The drop pattern: attacker lands a `.php` file (or a `.jpg`/`.png` masquerade with a `.htaccess` rewriting the extension to PHP) in one of the writable trees. Subsequent access loads the file under the web user's PHP process. Cleanup that only checks `app/code/` and `vendor/` misses these paths.

## vendor/ tree as hiding ground

The `vendor/` tree is composer-managed and large. A typical Magento 2.4 install ships ~30k files under `vendor/`. Attacker hiding strategy is to drop a `.php` file inside an existing legitimate package directory — `vendor/magento/framework/Filesystem/<random>.php`, `vendor/symfony/console/<random>.php` — where casual review skips it as part of the framework.

Triage approach:

- Compare the on-disk `vendor/` tree against a fresh `composer install` from the locked versions in `composer.lock`. Any file present on disk but not in the fresh install is suspect.
- `find vendor/ -name '*.php' -newer composer.lock` surfaces `.php` files modified after the last composer operation. Few false positives once `composer.lock` is itself trusted.
- Hash every `.php` under `vendor/` and diff against the package-distributed hashes. Composer 2 stores SHA-1 and SHA-256 in the lock file's `dist.shasum`, but per-file hashes require pulling the package archive separately.

## Magento_Backend and admin module poisoning

`Magento_Backend` is the core module that defines the admin area routing, controller dispatch, and ACL. A modification to `app/code/Magento/Backend/` or `vendor/magento/module-backend/` files that is not part of a Magento patch release is a high-severity finding — it can disable admin auth, log credentials, or insert a backdoor admin user on every login.

Specific files to baseline:

- `vendor/magento/module-backend/Controller/Adminhtml/Auth/Login.php` — the login controller. Any modification is alarming.
- `vendor/magento/module-backend/App/AbstractAction.php` — admin request lifecycle. Modifications can bypass auth.
- `vendor/magento/framework/App/Bootstrap.php` — application bootstrap. Modifications can inject prepended code on every request.

Magento ships package hashes in the upstream tarball; comparing against the version's official release archive is the cleanest verification.

## env.php and config.php tampering

`app/etc/env.php` holds the database credentials, encryption key, admin frontName, and crypt key. Modifications are operator-legitimate at install and on `setup:upgrade`; out-of-band modifications are not.

`app/etc/config.php` holds the enabled-modules list and the system-config defaults. New module entries here without a corresponding `composer.json` and `app/code/` or `vendor/` directory point to a fake module hooking the loader.

Both files have a stable structural format — PHP arrays with predictable key order. A diff against a backup catches added entries cleanly; a content review catches obfuscated payloads inserted as string values.

## Log paths to read

For Magento-specific evidence:

- `var/log/exception.log` — uncaught exceptions, often the noisiest indicator that something is misbehaving.
- `var/log/system.log` — `info`/`notice` level events, including admin login success and failure when configured.
- `var/log/debug.log` — only populated when debug mode is on; usually off in production.
- `var/report/<id>` — error reports referenced from the user-facing error page. The report ID format is documented; an attacker with the ID can pull stack traces.

For web-server evidence corroborating Magento findings:

- Apache access log — usually `/var/log/apache2/<vhost>-access.log`, `/var/log/httpd/access_log`, or per-tenant `/home/<user>/logs/<vhost>-bytes_log` on cPanel.
- nginx access log — `/var/log/nginx/access.log` or vhost-specific.

`source_refs` in evidence rows should cite the specific log line or file path; the case engine reads citations, not raw log content.

<!-- public-source authored — extend with operator-specific addenda below -->
