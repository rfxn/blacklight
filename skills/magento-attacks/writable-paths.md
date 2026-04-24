# magento-attacks — writable paths and drop-zone analysis

Loaded alongside `admin-paths.md` when the host stack includes Magento 2.x. Pairs with that file for the admin-surface side of the picture; this file covers the writable-directory side — where adversary drops land and how to separate legitimate writable-directory content from planted artifacts.

Authoritative references: Adobe Commerce Developer Docs file layout and permissions (`experienceleague.adobe.com/docs/commerce-operations/installation-guide/prerequisites/file-system/overview.html`); Adobe Commerce deployment docs for `generated/` and `pub/static/` semantics (`experienceleague.adobe.com/docs/commerce-operations/configuration-guide/cli/set-mode.html`); Apache `mod_rewrite` documentation for `.htaccess` directive scope (`httpd.apache.org/docs/current/mod/mod_rewrite.html`). Cross-reference `admin-paths.md:49-56` for the vendor-hiding discussion and `admin-paths.md:62-69` for the `composer.lock` baseline pattern — this file does not duplicate, it extends.

---

## Writable-directory map

Every directory below is writable by the PHP process that serves Magento. The blast radius of a write depends on whether the directory is served by the web server (dropper is reachable via URL) and whether PHP execution is expected in it (dropper can execute without a separate `.htaccess` change).

- `pub/media/` — uploaded product images, category images, customer-upload content. Writable. Served by the web server (URL-reachable). PHP execution is **not** expected; `.php` here is anomalous. Subdirectory breakdown below.
- `pub/media/wysiwyg/` — admin WYSIWYG image/file uploads. Served.
- `pub/media/catalog/product/` — product-gallery images. Served. Deep directory tree with SHA-prefix bucketing (`/p/r/product-img.jpg`).
- `pub/media/customer/` — customer-profile avatars on installs that expose them. Served.
- `var/cache/` — runtime cache. Writable. **Not** served by default. A `.htaccess` or server-config change that exposes this directory opens a drop path.
- `var/tmp/` — working files for long-running operations (import, export, queue). Writable. Not served.
- `var/session/` — PHP session files when session storage is filesystem-backed. Writable. Not served.
- `var/log/` — Magento application logs (`exception.log`, `system.log`, `debug.log`). Writable. Not served.
- `generated/` — DI-generated PHP (dependency-injection wiring classes generated at deploy time). Writable during `setup:di:compile`. `.php` execution here **is** expected as part of Magento's normal runtime — a high-quality hiding ground. `admin-paths.md:58` covers this.
- `pub/static/` — generated static assets (CSS, JS, images). Writable during `setup:static-content:deploy`. Served. `.htaccess` permitting PHP execution here is anomalous.

Legitimate file types per directory:

| Directory | Expected | Anomalous |
|---|---|---|
| `pub/media/wysiwyg/` | `.jpg`, `.png`, `.gif`, `.pdf`, `.doc*`, `.zip` | `.php`, `.phtml`, `.htaccess` with handler directives |
| `pub/media/catalog/product/` | `.jpg`, `.png`, `.webp` | Anything else, especially `.php` with image extension in URL |
| `var/cache/` | `.dat`, hash-named no-extension files, `.php` files named for cache classes | `.php` with entry-point shapes (eval loaders, function defs named generically) |
| `var/session/` | `sess_<hash>` files | `.php`, `.phtml` |
| `generated/` | `.php` under `generated/code/`, `generated/metadata/` | `.php` outside the known subtrees, `.php` with mtime outside the deploy window |
| `pub/static/` | `.js`, `.css`, `.svg`, `.woff*`, `.map`, deploy-generated `.php` files | `.php` not in the deployment manifest, `.htaccess` enabling PHP handlers |

The PolyShell family (`webshell-families/polyshell.md:13`) favors `pub/media/wysiwyg/.system/`, `pub/media/*/cache/`, and `generated/` because the directory is writable + reachable + executes PHP in at least one case. The `.cache` / `.system` / `.tmp` dotted-leaf naming hides from cleanup tooling that filters on `*.php` at the public-root level.

---

## .htaccess override vectors

`admin-paths.md:49-56` covers the tenant abuse vectors; the writable-path view adds placement strategy. An adversary who has write to `pub/media/` but does not yet have PHP execution writes an `.htaccess` first, then drops a dual-extension file.

Common directive patterns:

```apache
# Route .jpg requests to PHP handler — pair with a .jpg file that is actually .php content
RewriteRule ^(.+)\.(jpg|png|gif|webp)$ $1.php [L]

# Register PHP handler for image extensions — same outcome, shorter
AddHandler application/x-httpd-php .jpg .png .gif

# Prepend adversary loader to every PHP request in this tree
php_value auto_prepend_file /home/<user>/public_html/pub/media/.cache/loader.php

# Enable CGI execution where it was off
Options +ExecCGI
AddHandler cgi-script .pl .py
```

Triage approach for a suspected writable-path compromise:

1. `find <docroot> -name .htaccess -newer <reference>` to enumerate recently-modified overrides.
2. For each hit, grep for handler-changing directives: `AddHandler`, `SetHandler`, `RewriteRule.*\.php`, `auto_prepend_file`, `auto_append_file`, `php_value`, `Options.*ExecCGI`.
3. Pair each suspect `.htaccess` with a directory listing of `*.jpg`, `*.png`, `*.gif` in the same tree — image files with PHP content-type sniffing signatures (first-line `<?php` or base64-loader patterns) are the drop partner.

`hosting-stack/cpanel-anatomy.md:58` names the enumeration command: `find <docroot> -name .htaccess -exec stat -c '%Y %n' {} +` sorted by mtime. That command feeds both this review and the broader cPanel-hosted triage.

---

## Legitimate-vs-anomalous heuristics per directory

For each writable directory, the responder needs a one-question triage test:

- `pub/media/` — "Is this a `.php` or a `.phtml`?" If yes, anomalous. If it is an image or a document, hash-match against the Magento admin upload record in the `media_gallery` table.
- `var/cache/` — "Does the filename match a known cache-class naming convention?" Magento caches are named for their class (`mage-tags`, `config_cache`, `layout_cache`). Random-named `.php` files are anomalous.
- `generated/` — "Is the file under `generated/code/` or `generated/metadata/`, and does its mtime fall inside a known deploy window?" Both conditions required for benign; either failure is a review flag.
- `pub/static/` — "Does the file appear in `pub/static/deployed_version.txt`'s generation manifest?" A file not in the manifest is not from the deploy run.

These heuristics produce evidence records in `bl-case/CASE-<id>/evidence/evid-*.md`. The curator reads the record's yes/no answer plus the citation (`source_refs`), not the file content.

---

## composer.lock diff strategy

The baseline comparison for every writable-path triage:

1. Read `composer.lock` to get the locked package set.
2. Run `composer install --dry-run` against a fresh checkout at that lock (`admin-paths.md:68`). This produces the expected on-disk tree without touching the live site.
3. Hash every `.php` under `vendor/` and under `generated/code/`, and diff against the fresh-install tree.
4. Files present on disk but absent from the fresh install are the candidate set. Files present in both but with different hashes are modified.
5. For `generated/` specifically, the output of `setup:di:compile` is deterministic for a given input tree — re-running the compile step in a staging environment gives the expected `generated/` contents to compare against.

`admin-paths.md:62-69` covers the `vendor/` tree side of the comparison. This file extends to the `generated/` tree, which `admin-paths.md` does not cover.

The comparison is defensive — never touch the live site with `composer install`. The fresh checkout runs in an isolated copy of the repository with the same `composer.lock` and `composer.json`.

---

## What to capture into evidence records

Every writable-path finding produces at least one evidence record under `bl-case/CASE-<id>/evidence/evid-*.md`. The record's `source_refs` cite:

- **path** — full path from docroot root, normalized (no trailing slashes, no `..` segments).
- **mtime** — ISO-8601 UTC from `stat -c '%y' <file>`. Mtime drives windowing in later correlation.
- **owner** — `stat -c '%U:%G' <file>`. Tenant attribution per `hosting-stack/cpanel-anatomy.md:40-45`.
- **composer-baseline result** — one of `present-in-lock-matching-hash`, `present-in-lock-modified-hash`, `not-in-lock`. The three-way split is what the curator reads.
- **governing `.htaccess` chain** — list of `.htaccess` files from docroot down to the path's parent directory, each with its mtime and a one-line summary of handler-affecting directives.
- **request-log correlation** — any access-log line hitting the file in the last 90 days. Format: `<timestamp> <method> <uri> <status> <bytes> <user-agent>`.

The evidence-record format itself is defined by `ir-playbook/case-lifecycle.md`; this file only names which fields a writable-path finding must populate.

<!-- public-source authored — extend with operator-specific addenda below -->
