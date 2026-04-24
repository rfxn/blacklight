# Cleanup Choreography

**Source authority:**

- NIST SP 800-61 r2 §3.3 (Eradication and Recovery): <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-61r2.pdf>
- R-fx Linux Malware Detect project: <https://rfxn.com/projects/linux-malware-detect/>
- chattr(1) man page: <https://man7.org/linux/man-pages/man1/chattr.1.html>
- chmod(1) man page: <https://man7.org/linux/man-pages/man1/chmod.1.html>
- R-fx Magento PolyShell mitigation guide: <https://rfxn.com/research/>

The curator loads this skill when emitting `clean.*` tier-destructive steps — the ordering below is what makes the operation reversible up to the moment of deletion and verifiable as complete afterward. Every `clean.*` verb is tier-destructive per `docs/action-tiers.md`; the wrapper's backup gate enforces the first stage before the rest proceed.

---

## The backup-quarantine-remove-audit ordering

The 4-stage sequence is mandatory and non-negotiable in its ordering. Each stage is a prerequisite for the next; skipping stages eliminates the safety margin that makes the operation reversible.

| Stage | Action | Safety margin |
|-------|--------|---------------|
| 1 — Backup | Archive affected paths off-host | Full reversal possible at any later stage |
| 2 — Quarantine | Revoke permissions; optionally lock with chattr | File still on disk; operator can inspect or restore |
| 3 — Remove | Delete from disk | Cannot reverse; backup is the only path back |
| 4 — Audit | Rescan; verify no persistence mechanism survived | Confirms eradication is complete |

The LMD `maldet -q` workflow runs stages 2 and 3 atomically (quarantine-then-move) — it is appropriate when the operator does not require a manual inspection window between stages. For high-stakes eradications (production commerce hosts, payment flows), perform each stage manually so the team can verify before advancing.

---

## Stage 1 — Backup

Create a time-stamped quarantine archive of the affected paths before touching any file:

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
QUARANTINE_DIR="/root/incident-quarantine/${TIMESTAMP}"
mkdir -p "${QUARANTINE_DIR}"

# Capture all files modified in the suspected compromise window:
find /home/store/public_html -newer /tmp/compromise-window-start.flag \
    -type f \
    | tar --files-from=- -czf "${QUARANTINE_DIR}/affected-files.tar.gz"

# Checksum the archive immediately:
sha256sum "${QUARANTINE_DIR}/affected-files.tar.gz" > "${QUARANTINE_DIR}/affected-files.tar.gz.sha256"
```

Store the archive and its checksum off-host (NFS, S3, or analyst workstation) before advancing to stage 2. An on-host archive is better than nothing but is at risk if the adversary has a write primitive still active.

`find ... -newer` uses a sentinel file with the `touch -t` timestamp of the suspected compromise start. If the window start is unknown, use the earliest LMD hit timestamp from `hits.hist`.

---

## Stage 2 — Quarantine

Quarantine revokes the file's ability to execute or be served without deleting it, preserving the artifact for inspection:

```bash
# Revoke all permissions (execute gate):
chmod 000 /home/store/public_html/pub/media/custom_options/quote/xyz.gif

# Lock against further modification (ext2/3/4 and compatible filesystems only):
chattr +i /home/store/public_html/pub/media/custom_options/quote/xyz.gif
```

**`chattr +i` scope:** the immutable attribute requires a root-capable process to remove (`chattr -i`). It prevents the file from being overwritten, deleted, or renamed — including by the web server process. On filesystems that do not support extended attributes (tmpfs, some NFS mounts, FAT-backed shares), `chattr` returns an error and the lock is not applied. Verify with `lsattr` after setting.

**SELinux / AppArmor caveat:** on SELinux-enforcing hosts, the web server process may be prevented from reading a file with no execute permission but correct SELinux context — verify that quarantine does not trigger a denial that generates noise in audit logs before the team is ready to explain it. Relabeling the file with a non-executable type (`chcon -t httpd_sys_content_ro_t`) is an alternative quarantine mechanism on SELinux hosts.

---

## Stage 3 — Remove

Remove only after the backup archive is confirmed off-host and the quarantine step is complete:

```bash
# Confirm archive exists and checksum matches before proceeding:
sha256sum -c "${QUARANTINE_DIR}/affected-files.tar.gz.sha256"

# Remove the quarantined files:
chattr -i /home/store/public_html/pub/media/custom_options/quote/xyz.gif
rm /home/store/public_html/pub/media/custom_options/quote/xyz.gif
```

**LMD reverse path:** if using `maldet --quarantine` (which moves files to LMD's quarantine directory), the restore path is `maldet --restore <quarantine-path>`. This is the only supported reverse path once LMD has moved a file — do not attempt to reconstruct the original path manually, as LMD records metadata in the quarantine index.

Remove only the confirmed-malicious files. Do not remove entire directories unless content audit confirms all files within are either malicious or expendable — an over-broad remove that takes down legitimate application files extends the incident.

---

## Stage 4 — Audit

Re-scan after removal to confirm eradication and detect persistence mechanisms:

```bash
maldet --scan-all /home/store/public_html
```

Record the scan session ID from the output and retain the `sess/session.<ID>` file. The audit scan result is part of the documentation trail.

**The returning-shell pattern:** a shell that reappears after confirmed removal indicates a persistence mechanism — cron job, MOTD hook, an undetected dropper elsewhere in the tree, or a writeable include path that regenerates the shell on the next PHP request. Do not declare the host clean until the returning-shell protocol is complete.

---

## The returning-shell verification protocol

After stage 3 (remove), execute this protocol before declaring eradication complete:

1. **T+0 scan (immediate):** Run a full maldet scan immediately after removal. Baseline that all targets show `0 hits`.
2. **T+1h scan:** Re-scan the same path scope one hour after removal. A shell that reappears within one hour is being regenerated by an active dropper or a cron job running at an hourly or sub-hourly interval.
3. **T+24h scan:** Re-scan at 24 hours. Daily cron jobs (common in commodity malware kits) regenerate the shell once per day.
4. **T+7d scan:** Final verification at 7 days. Weekly persistence (rare but documented) and hosting-panel automation cycles that redeploy from a compromised template.

A clean result at all four checkpoints is the eradication confidence threshold. Document all four scan session IDs in the documentation trail.

---

## Credential rotation triggers

Credential rotation is mandatory when any of the following is confirmed:

**Rotation is required when the shell had:**

- File-write capability (any confirmed file drop) → web server user credentials, app DB connection string, Magento admin credentials
- Shell-execute capability (`system()`, `passthru()`, `exec()`, `proc_open()`, backtick) → all of the above plus OS-level service accounts the web server user can `sudo` to
- HTTP request forwarding (proxy or curl primitive) → external API keys stored in the application config (payment processor, shipping API, CDN origin key)

**Credential rotation checklist:**

- [ ] Server SSH host keys — regenerate and distribute to known clients
- [ ] Application DB password — rotate in DB and update all app config files that reference it
- [ ] Payment API keys (Stripe, Braintree, PayPal) — invalidate and reissue via the payment provider's dashboard
- [ ] Magento admin-panel credentials — reset all admin accounts; check for added admin accounts with unexpected email domains
- [ ] CDN / hosting-panel API keys — rotate if accessible from the web server user's process environment
- [ ] Any .env or secrets file readable by the web server user — treat all values as compromised

Do not defer credential rotation to a follow-up task. Rotate before the host is returned to service.

---

## The documentation trail

Produce and retain the following artifacts as the operation proceeds:

| Artifact | Contents | When captured |
|----------|----------|---------------|
| Pre-cleanup file inventory | `find ... -newer ... -ls` output, including mtime, owner, permissions | Stage 1, before any changes |
| File hashes | `sha256sum` on each confirmed-malicious file before removal | Stage 1 |
| Quarantine archive path + hash | Absolute path to `.tar.gz` and its `.sha256` file | Stage 1 |
| Post-cleanup verification scans | `maldet --scan-all` session IDs at T+0, T+1h, T+24h, T+7d | Stage 4 + protocol |
| Credential rotation log | Which credentials were rotated, by whom, at what timestamp | During rotation |
| Incident summary | Timeline of discovery, containment, eradication, recovery; open questions; no-attribution statement if attribution is incomplete | On close |

The documentation trail serves three post-incident purposes: legal/regulatory obligation, re-opening the investigation if a second wave follows, and customer communication if the operator is a managed-service provider with disclosure obligations.

---

## Failure modes

| Failure mode | Why it is dangerous | Correct approach |
|---|---|---|
| Delete first, backup later | Backup window is zero; eradication is irreversible before forensic capture | Always backup before delete |
| `rm -rf` on the upload directory | Removes legitimate files; may delete logs or sessions needed for forensic analysis | Remove only confirmed-malicious files by exact path |
| Declaring clean after T+0 scan only | Daily or weekly persistence is not visible at T+0 | Follow the 4-checkpoint protocol |
| Rotating only the DB password | Other credentials (SSH keys, API keys, admin accounts) remain compromised | Rotate the full checklist |
| Skipping `chattr +i` because it is optional | Without the immutable bit, a still-running dropper can overwrite the quarantined file before the team removes it | Apply `chattr +i` unless the filesystem provably lacks support |

---

## Triage checklist

- [ ] Stage 1: quarantine archive created, off-host, checksum verified
- [ ] Stage 2: `chmod 000` applied to all confirmed-malicious files; `chattr +i` applied on supported filesystems
- [ ] Stage 3: checksum re-verified before `rm`; LMD quarantine index consulted if `maldet --quarantine` was used
- [ ] Stage 4: T+0 scan run, session ID recorded
- [ ] Returning-shell protocol: T+1h, T+24h, T+7d scans scheduled
- [ ] Credential rotation: full checklist completed before host returned to service
- [ ] Documentation trail: all 6 artifact types captured
- [ ] Incident summary written; open questions noted

---

## See also

- [../linux-forensics/maldet-session-log.md](../linux-forensics/maldet-session-log.md)
- [../webshell-families/polyshell.md](../webshell-families/polyshell.md)
- [../magento-attacks/admin-backdoor.md](../magento-attacks/admin-backdoor.md) — the delete-order rule for `.htaccess` + PHP combinations
- [../ir-playbook/case-lifecycle.md](../ir-playbook/case-lifecycle.md) — where eradication sits in the case lifecycle

<!-- adapted from beacon/skills/remediation/cleanup-choreography.md (2026-04-23) — v2-reconciled -->
