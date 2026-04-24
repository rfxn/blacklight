# Base64 Chain Obfuscation

Base64 chains are the most common PHP webshell obfuscation technique. The payload is encoded one or more times, and the shell's initialization code peels each layer at runtime. The goal is to make the file content unreadable to humans and to defeat scanners that match known payload strings. The curator invokes this skill after `observe.file` surfaces a candidate shell — decode depth and transform sequence are evidence rows that feed attribution.

---

## Layer types

### Single (not a chain — baseline)

```php
eval(base64_decode('...'));
```

Not a chain. A single `base64_decode` is the baseline case found in minimal eval shells and simple polyshell variants. It will survive most content filters but is widely detected.

### Double base64

```php
eval(base64_decode(base64_decode('...')));
```

The inner blob decodes to another base64 string; the outer decodes to PHP code. Adds one round of encoding. The encoded string in a double-base64 shell will typically appear as a longer, sometimes partially-readable blob.

**Deobfuscation:**
```bash
php -r "echo base64_decode(base64_decode('<blob>'));"
```

### Triple base64 (gif-triplebase64 variant)

```php
eval(base64_decode(base64_decode(base64_decode('...'))));
```

Documented in the PolyShell APSB25-94 `gif-triplebase64` variant. Three layers defeat most single-pass decode tools. The encoded blob grows with each additional layer because base64 expands data by ~33%.

**Deobfuscation:**
```bash
php -r "echo base64_decode(base64_decode(base64_decode('<blob>')));"
```

### base64 + rot13

```php
eval(base64_decode(str_rot13('...')));
```

or in reverse:

```php
eval(str_rot13(base64_decode('...')));
```

ROT13 is applied to the base64 alphabet, not the payload bytes. The order matters: `rot13(base64)` vs `base64(rot13)` produce different results. This is a low-complexity addition that defeats scanners checking for valid base64 strings.

**Deobfuscation:**
```bash
php -r "echo base64_decode(str_rot13('<blob>'));"
# or
php -r "echo str_rot13(base64_decode('<blob>'));"
```

### base64 + strrev

```php
eval(base64_decode(strrev('...')));
```

The encoded string is stored reversed. Reversal is applied before base64 decoding. Trivial to peel but defeats string-matching on the raw file content.

### Split-string + base64

The function name or the encoded blob is split to defeat function-name signatures:

```php
$f = 'base'.'64_decode';
eval($f('...'));
```

or:

```php
$a = 'ZXZhb'; $b = 'A=='; eval(base64_decode($a.$b));
```

Split-string reassembly requires dynamic analysis or manual concatenation.

### Variable function chain

Combines variable function calls with base64 to hide both the execution primitive and the payload:

```php
$d = 'base64_decode';
$e = 'ev'.'al';
$e($d($d('...')));
```

---

## Identification heuristics

When scanning a PHP file, these patterns indicate a base64 chain:

1. `base64_decode` appears more than once on the same expression line
2. A long quoted string (> 200 chars) of `[A-Za-z0-9+/=]` characters is present
3. `eval(` immediately wraps a decode call
4. Function name is assembled from string concatenation (`'base'.'64_decode'`)
5. `str_rot13`, `strrev`, `str_replace` appear alongside `base64_decode` and `eval`

---

## Safe deobfuscation procedure

Run all decode operations in a sandboxed PHP environment. Never execute the decoded payload. The goal is to reach the plaintext PHP code for static analysis.

```bash
# Step 1 — identify outermost transform
grep -oP "eval\([^)]+\)" suspicious.php | head -5

# Step 2 — extract the blob
# (manually or with a PHP one-liner that replaces eval with echo)

# Step 3 — peel layers iteratively
php -r "echo base64_decode('<outer_blob>');" > /tmp/layer1.txt
file /tmp/layer1.txt  # check if still base64 or PHP

# Step 4 — repeat until PHP code is visible
php -r "echo base64_decode(file_get_contents('/tmp/layer1.txt'));" > /tmp/layer2.txt
```

Replace `eval` with `echo` or `file_put_contents` in any PHP one-liners — never let the decoding step execute the payload.

---

## Chain depth quick reference

| Pattern | Layers | Detection Difficulty |
|---------|--------|----------------------|
| Single base64 | 1 | Low |
| Double base64 | 2 | Low |
| Triple base64 | 3 | Medium |
| base64 + rot13 | 2 | Medium |
| Split-string + base64 | 1–2 | Medium |
| Variable function + chain | 2+ | High (requires dynamic analysis) |

---

## Triage checklist

- [ ] Count `base64_decode` occurrences in the file
- [ ] Identify any auxiliary transforms (rot13, strrev, str_replace)
- [ ] Check for split function name construction
- [ ] Peel each layer in a sandboxed PHP CLI, replacing eval with echo
- [ ] Identify the final payload (cross-reference `../webshell-families/`)
- [ ] Document chain depth and transform sequence for the evidence row

---

## See also

- [gzinflate.md](gzinflate.md) — compression-based outer layer often combined with base64 chains
- [../webshell-families/polyshell.md](../webshell-families/polyshell.md) — PolyShell triple-base64 variant
- [../webshell-families/minimal-eval.md](../webshell-families/minimal-eval.md) — minimal eval-based dispatch with single-layer base64

<!-- adapted from beacon/skills/obfuscation/base64-chains.md (2026-04-23) — v2-reconciled -->
