# false-positives — vendor-tree allowlist patterns

Loaded by the router when a flagged file lands inside a tree that is composer-managed, plugin-vendored, or otherwise upstream-owned. Pairs with `backup-artifact-patterns.md` for the non-vendor false-positive class. This file is the lookup of *what benign vendor content looks like* and *which properties separate a legitimate vendor file from an attacker-planted one in the same tree*.

Authoritative references: Adobe Commerce Developer Docs file layout (`experienceleague.adobe.com/docs/commerce-operations`); Composer spec for PSR-4 autoload and `composer.lock` integrity (`getcomposer.org/doc/04-schema.md`); WordPress Plugin Directory README conventions (`developer.wordpress.org/plugins/wordpress-org/`). The allowlist patterns here derive from these sources — any entry the responder adds from operator context belongs below the footer marker, not here.

---

## Magento vendor/ tree

A pristine Magento 2.4 install drops roughly 30 000 files under `vendor/`. The load-bearing subtree map:

- `vendor/magento/framework/` — core framework. PHP classes under `View/`, `App/`, `Filesystem/`, `Event/`, `Data/`. Every file is composer-installed and hash-checkable against the package archive. A modification here is a P0 finding — see `magento-attacks/admin-paths.md:77-82` for the specific files that must be baselined.
- `vendor/magento/module-<name>/` — per-module trees (module-backend, module-customer, module-catalog, etc.). The naming follows `magento/module-<snake-case>` at package level, `Magento_<CamelCase>` at module-registration level.
- `vendor/composer/` — Composer's own runtime: `autoload_real.php`, `autoload_psr4.php`, `installed.json`, `installed.php`. Regenerated on every `composer install` / `composer update`. Timestamps cluster at deploy moments.
- `vendor/symfony/console/`, `vendor/symfony/process/`, `vendor/symfony/event-dispatcher/` — Symfony components pulled transitively by Magento framework. Benign. High file count.
- `vendor/laminas/`, `vendor/zendframework/` — Zend Framework / Laminas components. Benign. Present on most Magento 2.x installs.
- `vendor/guzzlehttp/guzzle/`, `vendor/psr/log/`, `vendor/monolog/monolog/` — common HTTP-client and logger deps. Benign.

The Composer-managed invariant: every file under `vendor/` is either (a) named in `composer.lock` under a package's `dist.shasum` hash, or (b) regenerated deterministically from sources (e.g., `vendor/composer/autoload_*.php`). A file matching neither case inside `vendor/` is not upstream content.

Concrete benign-path examples the hunters flag and then resolve via the allowlist:

- `vendor/magento/framework/View/Element/Template.php` — template rendering primitive. Present on every install, ~2 KB.
- `vendor/magento/module-backend/Controller/Adminhtml/Index/Index.php` — admin dashboard controller entry.
- `vendor/composer/autoload_classmap.php` — generated class map. One entry per declared class across every installed package.
- `vendor/symfony/console/Application.php` — the Symfony Console kernel. Referenced transitively from Magento CLI.
- `vendor/laminas/laminas-http/src/Client.php` — Laminas HTTP client core.

Each path maps 1:1 to a package entry in `composer.lock`. Absence from the lock is the disqualifier.

---

## WordPress plugin and theme trees

WordPress false-positive territory follows similar rules with a looser upstream discipline — not every plugin ships from the Plugin Directory with hash verification.

- `wp-content/plugins/<plugin-slug>/` — installed plugin root. Conventionally contains `<plugin-slug>.php` as the main file with a header block naming `Plugin Name:`, `Version:`, `Author:`. Readme at `readme.txt` follows the Plugin Directory format.
- `wp-content/plugins/<plugin-slug>/vendor/` — plugins that bundle their own Composer deps. Common in commercial plugins (WooCommerce extensions, page builders). This is a vendor tree inside a vendor tree; the same Composer-managed invariant applies if the plugin ships a `composer.lock`.
- `wp-content/mu-plugins/` — must-use plugins. Files here load on every request without appearing in the plugin list. Legitimate use is rare; the directory is a persistence-favorite. Flag every file here for review; resolve as FP only against an explicit operator allowlist.
- `wp-content/themes/<theme>/` — theme root. Minified `.js`, `.css`, and occasional `.php` template files. Modifications via the WordPress admin theme editor leave files with the web-user owner and a mtime unrelated to any deploy window.

Plugin-content false-positive hits on webshell hunters typically resolve through three signals: plugin slug matches a directory-registered plugin; the file is part of a plugin archive pulled from a known source; the file hash matches the archive hash.

Theme-tree false-positive shapes the responder meets repeatedly: minified jQuery copies under `wp-content/themes/<theme>/assets/js/vendor/`, page-builder cached templates under `wp-content/uploads/<builder>-cache/`, and translation `.mo` / `.po` pairs under `wp-content/languages/`. Minified files trigger entropy-based hunters; the fix is hash-against-upstream rather than threshold tuning.

---

## Common signals that resolve a vendor-tree flag to FP

Four signals, in order of load-bearing strength:

1. **File ownership matches the vendor-install baseline.** On a cPanel host with suEXEC or PHP-FPM per-user pools, every file under `vendor/` is owned by `<user>:<user>`. A file owned by `root:root` or `apache:apache` inside `/home/<user>/public_html/vendor/` is not composer-installed — see `hosting-stack/cpanel-anatomy.md:40-45` for the UID-attribution rules.
2. **File is named in composer.lock with a matching hash.** `composer install --dry-run` from a fresh checkout of the same `composer.lock` regenerates an identical tree. Any file on disk not present in the fresh install is attacker-planted; any file present in both but with a different hash is modified.
3. **File mtime falls within a deploy window.** Composer operations timestamp-stamp every file they touch. A `git log` of `composer.lock` gives the deploy windows; files with mtime in these windows match baseline. Files with mtime outside every deploy window are candidates for review.
4. **File content matches the package archive.** Adobe Commerce packages and Composer registry packages ship with declared `dist.shasum` (SHA-1, and SHA-256 in Composer 2). The per-file hash is not in the lock file — pulling the archive separately is the final resort when the other three signals conflict.

If all four signals align on "benign", the finding closes as FP. If signals 1-3 align but signal 4 diverges, the file is modified and the finding escalates.

---

## When the allowlist does not apply

Attackers know `vendor/` is the first place a responder stops looking. Three concrete abuse patterns:

- **Drop inside a real package directory.** An attacker writes `vendor/magento/framework/Filesystem/<random>.php` or `vendor/symfony/console/Helper/.shell.php`. Casual review treats the directory as trusted and skips the file. The composer.lock diff (signal 2) catches this immediately — the file is not in the package's file list. The countermove is routine: compare on-disk tree against fresh install, flag any extras.
- **Modify an existing package file.** An attacker patches `vendor/magento/framework/App/Bootstrap.php` to include a prepended loader. File path and ownership match baseline; only the hash (signal 4) diverges. The countermove is hash-diff against the package archive, which requires pulling the archive separately because per-file hashes are not in the lock.
- **Bury inside mu-plugins or an obscure plugin vendor tree.** An attacker drops `wp-content/mu-plugins/.system.php` or `wp-content/plugins/<real-plugin>/vendor/.cache/helper.php`. Plugin-vendor trees lack the strict Composer invariant Magento enjoys, so the hash-diff avenue is weaker. Rely on mtime + ownership + path anomaly (a `.cache` directory inside a plugin vendor tree is not standard).

For PolyShell-family drops specifically, see `webshell-families/polyshell.md:13` — the `.cache`, `.tmp`, `.system` dotted-leaf idiom survives most cleanup tooling that filters on `*.php` directly under recognized public roots.

---

## Triage checklist

For a flagged file under a vendor tree:

1. Resolve the owner with `stat -c '%U:%G' <file>`. Compare against the account's vendor baseline.
2. Open `composer.lock`. Grep for the file's package path; if absent, the package is not installed.
3. Run `composer install --dry-run` from a fresh checkout at the locked version and diff the generated tree against the on-disk tree.
4. If steps 1-3 all report benign, pull the package archive from the registry (Packagist for Composer, Plugin Directory for WordPress) and hash-compare the file.
5. On any divergence, treat the finding as modified-package and escalate per `skills/ir-playbook/case-lifecycle.md`.

Every step produces an evidence row; the case-engine reasoner reads the aggregated rows, not the file content itself.

<!-- public-source authored — extend with operator-specific addenda below -->
