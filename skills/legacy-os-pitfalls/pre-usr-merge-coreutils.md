# pre-usr-merge-coreutils — `/bin/` vs `/usr/bin/` and the portable resolution

Loaded by the router whenever the curator emits shell for any `clean.*` or `defend.*` step, and always-loaded when `substrate-report.os.usrmerge=false`. The `/usr` merge happened distro-by-distro between 2012 and 2020. Hosts on the pre-merge side — CentOS 6, RHEL 6, Ubuntu 12.04 — keep coreutils at `/bin/`, not `/usr/bin/`. Patches authored against post-merge convention break on those hosts.

## The lived failure

The curator emits a `clean htaccess` step whose patch body reads:

```bash
/usr/bin/cp "$f" "$f.quarantine.$(date +%s)"
/usr/bin/rm "$f"
```

Substrate has named the host as CentOS 6. The script lands; both binaries fail with `No such file or directory`. The patch records no evidence of the cleanup attempt — the wrapper exited before either invocation logged. The webshell is still in place; the case sits in `pending` until the operator authors a follow-up step by hand.

## Why the split exists

The `/usr` merge consolidates `/bin/`, `/sbin/`, `/lib/`, `/lib64/` into the `/usr/` tree, leaving the top-level paths as compat symlinks. Fedora proposed it in 2012 (https://fedoraproject.org/wiki/Features/UsrMove); Debian completed it across 2018-2021 via the `usrmerge` package; Ubuntu finished in 21.10. Rocky 8+, RHEL 8+, Debian 12, Ubuntu 20.04+ are post-merge.

CentOS 6 / RHEL 6 (EOL 2020) and Ubuntu 12.04 (EOL 2017) are pre-merge: `cp` lives at `/bin/cp`, and `/usr/bin/cp` does not exist as a symlink. Both persist on hosting fleets the provider cannot force-upgrade.

## The portable resolution rule

`command <util>` performs PATH-based resolution at runtime per the POSIX shell spec (https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#command). The shell finds `cp` wherever PATH places it — `/bin/cp` on pre-merge, `/usr/bin/cp` on post-merge — and bypasses any function or alias of the same name. One pattern works on every supported substrate:

```bash
command cp "$src" "$dst"
command rm -f "$path"
command chmod 0644 "$path"
command mkdir -p "$dir"
```

Same pattern for `cat`, `mv`, `touch -r`, `ln -sf`, and the rest of coreutils.

This matches the project's own source convention — see `CLAUDE.md` "Coreutils `command` prefix" for the full rule, enforced pre-commit by `grep -rEn '^\s*(cp|mv|rm|chmod|mkdir|touch|ln) ' files/`.

## Two failure modes that look like fixes

**Hardcoded `/usr/bin/<util>`** breaks on CentOS 6 / Ubuntu 12.04 — the path is wrong on the target. Hardcoded `/bin/<util>` has the symmetric failure on minimal Debian builds where `/bin -> /usr/bin` symlinks can be pruned.

**Backslash bypass** (`\cp ...`, `\rm ...`) skips aliases in interactive bash but is fragile: `dash` (Debian's `/bin/sh`) treats `\cp` as a literal name — a script under `/bin/sh` parses `\cp: command not found`. The project bans this everywhere.

## What the curator's emit must do

Every `clean.*` / `defend.*` patch body uses `command <util>` for every coreutils call. This applies to *generated* shell: a patch the curator emits is shell that runs on the substrate, which may be 4.1-floor / pre-merge. The curator's sandbox version is irrelevant; the target binds.

`printf` and `echo` are exceptions — bash builtins, used bare. `command printf` forces the external binary and is wrong in runtime scripts.

## Mitigation

Substrate's `os.usrmerge` field flags pre-merge hosts as a binding signal. When `false`, the `command <util>` rule is mandatory; when `true`, still preferred (post-merge `/bin/<util>` symlinks are sometimes pruned on minimal images).

## Cross-references

- `bash-4.1-floor-features.md`, `no-systemd-no-journal.md` — sister floor rules.
- Project `CLAUDE.md` "Coreutils `command` prefix" — canonical project-internal authority.

<!-- public-source authored — extend with operator-specific addenda below -->
