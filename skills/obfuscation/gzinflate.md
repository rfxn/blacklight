# gzinflate / gzuncompress / hex2bin Obfuscation

Compression-based obfuscation compresses the PHP payload, base64-encodes the result (because compressed data contains non-printable bytes), and stores it as a string literal. At runtime the shell decodes, decompresses, and evaluates the payload. The compression step makes the stored string significantly shorter for large payloads and produces a character distribution that can differ from plain base64. The curator reaches for this skill when a candidate shell is large (≥4 KB) and a single base64 layer decodes to binary garbage — compression is usually sitting between base64 and the real payload.

---

## Function reference

| PHP Function | Decompresses | Paired with |
|---|---|---|
| `gzinflate()` | raw DEFLATE stream | `base64_decode()` |
| `gzuncompress()` | zlib stream (DEFLATE with 2-byte header) | `base64_decode()` |
| `gzdecode()` | gzip stream (full gzip format) | `base64_decode()` |
| `hex2bin()` | hex-to-binary conversion | standalone or before `gzinflate` |

`gzinflate` is the most common in webshell drops. `gzdecode` is less common but functionally equivalent.

---

## Common patterns

### gzinflate + base64_decode (canonical form)

```php
eval(gzinflate(base64_decode('...')));
```

The blob is the base64 encoding of a raw DEFLATE-compressed payload. Decode base64 first, then inflate.

**Deobfuscation:**
```bash
php -r "echo gzinflate(base64_decode('<blob>'));"
```

### gzinflate + base64 chain

```php
eval(gzinflate(base64_decode(base64_decode('...'))));
```

A second base64 layer wraps the compressed blob. Peel in order: inner base64 → outer base64 → gzinflate.

### hex2bin prefix

```php
eval(gzinflate(base64_decode(hex2bin('...'))));
```

The blob is hex-encoded before base64 encoding. `hex2bin` converts the hex string to binary, then `base64_decode` produces the compressed data, then `gzinflate` produces PHP code. Hex-encoding the base64 string produces an all-hex-character blob that looks different from a standard base64 string (only `[0-9a-f]`).

**Deobfuscation:**
```bash
php -r "echo gzinflate(base64_decode(hex2bin('<blob>')));"
```

### str_rot13 outer wrap

```php
eval(gzinflate(base64_decode(str_rot13('...'))));
```

ROT13 is applied to the base64 string before storage. Apply `str_rot13` first, then `base64_decode`, then `gzinflate`.

### Variable function assembly

```php
$a = 'gz'.'inflate';
$b = 'base64'.'_decode';
eval($a($b('...')));
```

Function names split across string concatenation. The split position varies; `'gz'.'inflate'` is common, as is `'base64'.'_decode'`.

---

## Identification heuristics

1. File begins with `<?php eval(gz` or `<?php $<var>=gz` — gzinflate is the outermost transform.
2. A long base64-format string (> 500 chars) immediately follows the function call.
3. The base64 string does not decode to readable text (it decompresses to PHP code via gzinflate — plain base64 decode produces binary garbage).
4. `hex2bin` variant: the string consists entirely of `[0-9a-f]` characters in pairs.
5. `str_rot13` variant: the base64 alphabet is partially shifted (`n-z` and `A-N` characters appear at higher frequency).

---

## Deobfuscation procedure

All steps are run in a sandboxed PHP CLI. Replace `eval` with `echo` in every command.

```bash
# Step 1 — identify the transform stack from the file
grep -E "gzinflate|gzuncompress|gzdecode|hex2bin" suspicious.php

# Step 2 — extract the blob (the string argument to the outermost decode)
# Manual extraction: copy the string literal from the file

# Step 3 — peel hex2bin if present
php -r "echo hex2bin('<blob>');" > /tmp/after_hex.txt
# result is the base64 string

# Step 4 — peel base64
php -r "echo base64_decode(file_get_contents('/tmp/after_hex.txt'));" > /tmp/after_b64.bin
# result is compressed binary

# Step 5 — inflate
php -r "echo gzinflate(file_get_contents('/tmp/after_b64.bin'));" > /tmp/payload.php
# result is PHP source code

# Step 6 — inspect payload without executing
head -30 /tmp/payload.php
grep -E "eval|system|passthru|exec|shell_exec|base64" /tmp/payload.php
```

---

## PHP obfuscation tool fingerprints

Some PHP obfuscation tools produce recognizable outer wrappers. These are identified by the surrounding boilerplate, not by the payload content:

- **PHP Encoder (IonCube-style imitators):** Comment block at top claiming the file is encoded; `preg_replace` or `eval` wrapper with version string.
- **Zend Guard loader stubs:** Specific base64 prefix patterns and a call to `zend_loader_file_encoded()`.
- **Generic "PHP Shield" variants:** `$__` variable naming convention for the function references.

These are covered by `../false-positives/encoded-vendor-bundles.md` — load that skill before concluding a commercially-encoded legitimate file is malicious.

---

## Triage checklist

- [ ] Identify the compression function (gzinflate / gzuncompress / gzdecode)
- [ ] Identify any additional transforms (hex2bin, rot13, base64 chain)
- [ ] Document the transform stack order (outermost to innermost)
- [ ] Peel each layer in sandboxed PHP CLI with eval replaced by echo
- [ ] Identify the final payload type (cross-reference `../webshell-families/`)
- [ ] Check for variable function name assembly

---

## See also

- [base64-chains.md](base64-chains.md) — base64 chain layers that often sit inside gzinflate wrappers
- [../false-positives/encoded-vendor-bundles.md](../false-positives/encoded-vendor-bundles.md) — legitimate compressed PHP files
- [../webshell-families/polyshell.md](../webshell-families/polyshell.md) — payload identification after deobfuscation

<!-- adapted from beacon/skills/obfuscation/gzinflate.md (2026-04-23) — v2-reconciled -->
