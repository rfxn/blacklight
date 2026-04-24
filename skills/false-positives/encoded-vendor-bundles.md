# Magento vendor/ + Encoder False Positives

**Source authority:** Composer package conventions (<https://getcomposer.org/doc/02-libraries.md>), IonCube encoder product documentation (<https://www.ioncube.com/encoder.php>), Zend Guard encoder documentation (<https://www.zend.com/products/php-encoder>), SourceGuardian product documentation (<https://www.sourceguardian.com/>), Magento 2 extension developer guide (<https://devdocs.magento.com/guides/v2.4/extension-dev-guide/build/composer-integration.html>), R-fx LMD rule set documentation (<https://rfxn.com/projects/linux-malware-detect/>).

This skill addresses the second-largest FP class in Magento-hosted LMD deployments. Two distinct but overlapping mechanisms produce the same signal: (1) Composer-managed PHP packages whose legitimate code uses `eval`, reflection, `base64_decode`, and stream wrappers — all primitives that LMD signature rules match on — and (2) commercial PHP encoder products (IonCube, Zend Guard, SourceGuardian) that produce binary-encoded files with eval-based loader stubs. Both classes are endemic to Magento 2 installations. A naive escalation on either will produce noise that drowns real findings. The curator consults this skill before emitting a `defend.sig` step against a scanner rule that keeps tripping on vendor paths.

---

## The vendor/ tree FP class

Magento 2 installs approximately 200 Composer packages as part of its base platform. The `vendor/` directory is populated by `composer install` from `composer.lock` and is not operator-authored code. Scanner rules that fire on raw pattern presence rather than structural analysis will produce FPs across the entire Composer dependency tree.

Key LMD rules that generate FPs in this class:

| Rule ID | Pattern | FP source |
|---------|---------|-----------|
| `php.exec.classcheck` | `call_user_func`, `call_user_func_array` | Symfony DI container, Doctrine ORM |
| `php.cmdshell.callmethod` | `->__invoke(`, `$fn()` | Symfony Console, Guzzle middleware |
| `php.base64.decode` | `base64_decode(` | PHPMailer, Guzzle stream wrappers, Magento core |
| `php.eval.dynamic` | `eval(` | IonCube / Zend Guard loader stubs |
| `php.stream.wrapper` | `php://input`, `data://` | Guzzle PSR-7 stream adapters |

The common denominator is that these rules were designed to detect webshell primitives in isolation, but the primitives also appear in legitimate framework code under `vendor/`.

---

## Composer-installed package patterns

The following package-specific patterns are known FP triggers. If the flagged file resolves to one of these packages via `composer show`, the finding is a FP.

| Package | FP-triggering pattern | Elimination path |
|---------|----------------------|-----------------|
| `symfony/dependency-injection` | `call_user_func_array($callable, $args)` in compiled container | `composer show symfony/dependency-injection`; path confirms `vendor/symfony/dependency-injection/` |
| `guzzlehttp/guzzle` | `base64_decode($chunk)` in stream_for() wrapper | `composer show guzzlehttp/guzzle`; path confirms `vendor/guzzlehttp/` |
| `monolog/monolog` | `eval`-based formatter fallback in `NormalizerFormatter` | `composer show monolog/monolog`; path confirms `vendor/monolog/` |
| `zendframework/zend-code` | `eval($code)` in code generator tests | `composer show zendframework/zend-code` |
| `magento/framework` | `call_user_func` in event dispatch, `base64_encode` in URL signing | Path under `vendor/magento/framework/` |

**Confirm Composer ownership of a flagged file:**

```bash
# From the Magento root:
composer show --path 2>/dev/null | grep -F "$(dirname /path/to/flagged.php | sed 's|vendor/||')"
# If the package appears: the file is Composer-managed — proceed to hash check.

# Hash check against composer.lock recorded hash:
php -r "
  \$lock = json_decode(file_get_contents('composer.lock'), true);
  foreach (\$lock['packages'] as \$p) {
      if (strpos('/path/to/flagged.php', str_replace('/', DIRECTORY_SEPARATOR, \$p['name'])) !== false) {
          echo \$p['name'] . ': ' . (\$p['dist']['shasum'] ?? 'no shasum') . PHP_EOL;
      }
  }
"
```

If `composer.lock` records a shasum for the package and the installed package hash matches `composer validate --check-lock`, the file is clean.

---

## Encoder-wrapped files (IonCube / Zend Guard / SourceGuardian)

Commercial PHP encoders compile PHP source to a proprietary bytecode and prepend a loader stub. The stub is plain PHP that calls the encoder's runtime extension to decode and execute the payload. The stub contains `eval`-like patterns that trigger webshell rules.

**Header identification by encoder:**

| Encoder | Header signature | Extension required |
|---------|----------------|--------------------|
| IonCube | `<?php //` followed by `ionCube` comment, or `if(extension_loaded('ionCube Loader'))` | `ioncube_loader_lin_X.Y.so` |
| Zend Guard | `<?php @Zend;` or `zend_loader_file_encoded()` at top of file | `ZendGuard.so` or `ZendLoader.so` |
| SourceGuardian | `<?php //00` or `SourceGuardian` string in first 5 lines | `ixed.X.Y.lin` |

**Confirm encoder identity:**

```bash
head -5 /path/to/flagged.php
# IonCube: first line contains "ionCube" or "ioncube"
# Zend Guard: first line is "<?php @Zend;" or contains "@Zend"
# SourceGuardian: first line is "<?php //00" or contains "SourceGuardian"

# Confirm the correct extension is loaded:
php -m | grep -iE 'ioncube|zend.loader|sourceguardian'
```

**Vendor licensing pattern:** Encoded files are almost always in the vendor tree of a purchased extension (e.g., `app/code/Vendor/Module/`, `vendor/vendorname/module/`). The presence of a `composer.json` in the module root with `"type": "magento2-module"` is a strong corroborating signal. If the encoded file is under `app/code/` or `vendor/` and there is a corresponding `composer.json` or `registration.php`, treat as FP unless the mtime or hash check fails.

---

## Magento-specific FP paths

The following Magento 2 paths contain files that are generated, cached, or aggregated by the platform. Findings in these paths are nearly always FPs — the scanner is flagging platform-generated artifacts.

| Path prefix | Content type | Risk of true positive |
|-------------|-------------|----------------------|
| `app/code/Magento/` | Magento core module PHP | Very low — core files ship from `vendor/magento/` in CE; `app/code/Magento/` is rarely used except for core patches |
| `lib/internal/` | Magento internal libraries (Zend Framework, Laminas) | Very low — Magento-vendored libs; eval/base64 patterns common in code-generator utilities |
| `pub/static/_cache/` | Aggregated and minified JS/CSS | Negligible — build artifacts with no PHP execution |
| `pub/static/` (JS only) | RequireJS bundles, merged JS | Negligible — same as above |
| `var/cache/` | Magento compiled config, DI compiled output | Low — generated PHP classes; `var/cache/` has no direct web execution path |
| `var/page_cache/` | Full-page cache HTML blobs | Negligible — HTML, not PHP |
| `.composer/` | Composer cache directory | Very low — cached package archives; not executed directly |

**When a path-only match is insufficient:** If the flagged file is in one of these paths but is also flagged by a rule that typically has very low FP rates (e.g., `php.webshell.b374k`, `php.webshell.r57`), do not dismiss on path alone. Proceed to the full elimination checklist below.

---

## Elimination procedure

Work through these five steps in order. Document the result of each step in the evidence row before proceeding. Stop at the first definitive result.

1. **Path check.** Confirm the file is under a path in the Magento-specific FP paths table or under `vendor/`, `node_modules/`, or `.composer/`. If the path is outside all known FP paths (e.g., under `pub/media/`, `app/design/`, or an operator-authored directory), do not use this skill — escalate via `webshell-families/` routing.

2. **mtime check.** Compare the file mtime against the confirmed compromise window (start of incident timeline).
   ```bash
   stat -c '%y %n' /path/to/flagged.php
   # If mtime predates compromise window by more than 24h: strong FP signal.
   # If mtime is inside the window: do not dismiss — continue to step 3.
   ```

3. **Composer lock / package registry check.** Confirm the file belongs to a locked Composer package with a recorded checksum. If `composer validate --check-lock` exits 0 and the package hash matches, the installed file matches the lock-recorded source — it is a FP.
   ```bash
   composer validate --check-lock
   # exit 0: lock is satisfied — all packages match recorded hashes
   # exit non-0: lock mismatch — do not dismiss; investigate
   ```

4. **Encoder header check.** If the file is PHP and its first 5 lines match an encoder header (IonCube, Zend Guard, SourceGuardian), confirm the corresponding PHP extension is loaded and the file is in a purchased-extension path. If confirmed: FP.

5. **Cross-fleet hash check.** If steps 1–4 do not yield a definitive answer, compute the sha256 of the flagged file and compare against other hosts in the fleet running the same Magento version and extension set.
   ```bash
   sha256sum /path/to/flagged.php
   # If the hash appears on >= 2 other fleet hosts with no incident: strong FP signal.
   # If the hash is unique to this host: do not dismiss — escalate.
   ```

If all five checks support FP: document the elimination evidence (path, mtime, composer hash, encoder header, fleet hash) and close the finding. Do not mark FP until all applicable steps are documented.

---

## When NOT to mark as FP

Do not use this skill to dismiss a finding when any of the following apply:

- **Dual-signal files.** The file matches both a known FP pattern (encoder header, vendor path) AND a webshell-family pattern (b374k structure, R57 config block, uploaded-credential store). Dual-signal files require escalation — do not mark FP on path alone.
- **mtime inside the compromise window.** A vendor file modified during the confirmed incident window is suspicious regardless of its path. Even if the content looks like a legitimate encoder stub, a modified encoder file is an intrusion vector.
- **File under `pub/media/`.** The Magento media upload directory (`pub/media/`) has no legitimate reason to contain PHP files. A PHP file in `pub/media/` is a webshell candidate regardless of its content patterns.
- **No package-registry record.** If you cannot confirm the file belongs to a Composer-locked package (step 3 fails), an encoder product (step 4 fails), or a cross-fleet match (step 5 absent), do not dismiss the finding. Absence of registry confirmation is not confirmation of legitimacy.

---

## See also

- [backup-artifact-patterns.md](backup-artifact-patterns.md) — backup-derived FP class (overlapping path patterns)
- [vendor-tree-allowlist.md](vendor-tree-allowlist.md) — the allowlist discipline for operator-curated vendor trees
- [../webshell-families/polyshell.md](../webshell-families/polyshell.md) — when FP elimination fails
- [../obfuscation/base64-chains.md](../obfuscation/base64-chains.md) — base64 chain analysis when the file is not a known package
- [../obfuscation/gzinflate.md](../obfuscation/gzinflate.md) — gzinflate/eval chains that may be legitimate encoder output
- [../magento-attacks/admin-backdoor.md](../magento-attacks/admin-backdoor.md) — when a flagged Magento file is confirmed malicious

<!-- adapted from beacon/skills/false-positives/encoded-vendor-bundles.md (2026-04-23) — v2-reconciled -->
