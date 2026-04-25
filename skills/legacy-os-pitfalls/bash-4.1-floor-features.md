# bash-4.1-floor-features — prohibited 4.2+ idioms with NEWS-cited intro versions

Loaded with the bundle whenever any sister file binds, and additionally always-loaded when the curator emits shell content for any `clean.*` or `defend.*` step regardless of OS — the 4.1 floor protects post-merge distros from regressions too. CentOS 6 ships bash 4.1.2 per the RHEL 6 errata. Idioms introduced in 4.2 / 4.3 / 4.4 / 5.0 parse-fail on 4.1 hosts; the failures are silent on the curator's modern sandbox and only surface at the host.

## The lived failure

The curator authors a `clean cron` patch whose body uses `${var,,}` for case folding. CentOS 6 ships bash 4.1.2; `${var,,}` is bash 4.2+. The script parses on the curator's sandbox (Ubuntu 22.04, bash 5.x), validates clean against the test apachectl, and lands at the host with a quiet syntax error. The wrapper records "step failed" without distinguishing floor incompatibility from logic error.

## The prohibited list with version flags

Per `CLAUDE.md` "Bash 4.1+ Floor (CentOS 6)" — the canonical project-internal authority — the bash 4.1 floor prohibits a specific set of idioms, each dated by introducing version per the bash NEWS file (https://git.savannah.gnu.org/cgit/bash.git/tree/NEWS):

- **`${var,,}` and `${var^^}`** — case-modification expansion. Introduced in **bash 4.2**. On 4.1: parse error.
- **`mapfile -d`** — read-until-delimiter into array. `mapfile`/`readarray` existed in 4.0; the `-d` flag was added in **bash 4.4**. On 4.1: `mapfile: -d: invalid option`.
- **`declare -n` / `local -n`** — namerefs (variable-name indirection). Introduced in **bash 4.3**. On 4.1: `declare: -n: invalid option`.
- **`$EPOCHSECONDS` and `$EPOCHREALTIME`** — Unix-time builtins. Introduced in **bash 5.0**. On anything below 5.0: variables expand to empty string silently — uniquely poisonous because there is no parse error.
- **`declare -A` for global state when sourced from inside a function** — the BATS `load` trap. Associative-array support is 4.0+ at file scope, but `declare -A foo` inside a function creates a *local*, not a global, and vanishes when the function returns. `local -A foo` inside a function is safe. The diagnostic is an `unbound variable` error far from the cause.

## Workaround patterns per idiom

Each prohibited idiom has a 4.1-compatible equivalent:

```bash
# ${var,,}  →  tr
lower=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')

# mapfile -d $'\0' arr < <(find ... -print0)  →  while-read loop
arr=()
while IFS= read -r -d '' x; do
    arr+=("$x")
done < <(find ... -print0)

# declare -n ref=foo  →  printf -v / eval
printf -v "$dst_name" '%s' "$value"      # write
eval "value=\${$src_name}"               # read

# $EPOCHSECONDS  →  date
now=$(date +%s)

# declare -A in function  →  local -A in function, OR parallel indexed arrays at global scope
parallel_keys=()
parallel_vals=()
```

The project's own source uses `$SECONDS` (a 4.1+ builtin) for monotonic-elapsed measurement and `$(date +%s)` for wall-clock — see `src/bl.d/26-fence.sh` and `src/bl.d/27-outbox.sh` for the in-tree pattern.

## Verification is the target's bash, not the curator's

The curator's sandbox runs bash 5.x; `bash -n` there does not surface 4.1 incompatibilities. The substrate-read names `bash.version`; the parse-validation step targets that floor explicitly. The substrate-aware emit pipeline runs `bash -n` against the floor version (`bash-4.1` from the project's own test fleet) before any patch leaves the curator's emit phase.

## Failure mode named, with mitigation

**Failure:** curator emits `${var,,}` on CentOS 6. Script parse-fails; case stalls without a clean signal distinguishing floor-incompatibility from logic error.

**Mitigation:** substrate-report's `bash.version` gates the curator's clean-step authoring. When `bash.version<4.2`, the prohibited list above is binding and per-idiom workarounds are the canonical emit. The pre-commit grep `grep -rn '\${[a-z_]*,,}\|mapfile -d\|declare -n\|EPOCHSECONDS' bl src/bl.d/ skills/` is the project's own enforcement — the rule this file teaches is the rule the project honors.

## Cross-references

- `pre-usr-merge-coreutils.md`, `no-systemd-no-journal.md` — sister floor rules.
- Project `CLAUDE.md` "Bash 4.1+ Floor (CentOS 6)" section — canonical project-internal authority.
- Bash NEWS file (https://git.savannah.gnu.org/cgit/bash.git/tree/NEWS) — every feature dated by introducing version.

<!-- public-source authored — extend with operator-specific addenda below -->
