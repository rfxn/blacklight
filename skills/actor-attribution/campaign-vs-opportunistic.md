# Campaign vs Opportunistic — Classifier

**Source authority:** Sansec campaign-attribution methodology across the SessionReaper follow-up <https://sansec.io/research/sessionreaper-exploitation> and PolyShell <https://sansec.io/research/magento-polyshell> writeups, with behavioral tracking patterns from MITRE ATT&CK Enterprise <https://attack.mitre.org/matrices/enterprise/>.

The classifier answers one question for a cluster produced by `../ioc-aggregation/ip-clustering.md`: is this one actor running a coordinated campaign, or is it mass-scanning noise that happened to cluster loosely? The decision drives whether the cluster warrants a named entry in the brief's IOC section or gets folded into the "opportunistic noise" bracket. The curator writes the campaign-or-not verdict into `attribution.md` with the supporting signal list.

---

## Campaign signals (combine at least three)

No single signal is sufficient. A campaign label requires three or more of the following to co-occur across the cluster.

### Aligned target-path preference + aligned timing + overlapping time windows

Multiple IPs in the cluster hit the same target-path set, with the same timing shape (see [`timing-fingerprint.md`](timing-fingerprint.md)), during overlapping calendar windows. This is the strongest same-campaign signal — identical behavior across IPs is the definition of coordinated activity.

### Same TTPs across IPs

Every IP in the cluster drops files to the same specific directory set. For PolyShell-era incidents, Sansec has documented `accesson.php` being sprayed across a consistent set of 5–7 directories under `pub/media/`, `app/code/`, and `app/etc/` across multiple IPs — that repetition of the same directory set is a same-toolchain signal. Same persistence script, same victim. See [`../magento-attacks/admin-backdoor.md`](../magento-attacks/admin-backdoor.md) for the directory-spray pattern.

### Cross-CVE correlation — the playbook signal

**Rule:** IPs that hit both `/custom_options/` (PolyShell / APSB25-94) **and** `/customer/address_file/upload` (SessionReaper / APSB25-88 / CVE-2025-54236) within the same incident window are executing the PolyShell → SessionReaper playbook. This is a specific same-actor pattern — the two CVEs are used sequentially by operators who are tracking both Adobe bulletins and chaining them for maximum coverage across the Magento installed base.

The cross-CVE correlation is the single most diagnostic signal for a Magento-era campaign. An IP that hits only one CVE could be a scanner for that CVE; an IP that hits both is running a deliberate playbook. Two IPs in the same cluster both executing the playbook collapse to a single-actor label with high confidence.

### Consistent UA or UA-rotation pattern across IPs

IPs in the cluster present the same UA or the same sequence of UAs (e.g., every IP rotates `python-requests/2.x` → `Go-http-client/1.1` in the same order). Shared UA rotation orders are same-toolchain; they don't occur by chance.

---

## Opportunistic signals

Any one of these, at the cluster level, is evidence of opportunistic / noise activity rather than coordinated campaign.

- **Target-path preference matches a known commercial-scanner signature.** Censys, Shodan, BinaryEdge, and other internet-wide scanners publish their scanning patterns — an IP cluster whose target-path set matches a published scanner profile is almost certainly research noise.
- **IP is in a known research ASN.** Research institutions (universities, certified-research cloud projects) publish their ranges; hits from those ranges are research probes by default.
- **Single request per IP with no follow-up.** A cluster of IPs each sending one request to the vulnerable endpoint and never returning is scanner noise, not a campaign — campaigns return to verify and exploit.
- **Broad target list across the cluster.** If the cluster's IPs collectively hit dozens of unrelated vulnerable endpoints (WordPress `/wp-login.php`, Magento `/custom_options/`, phpMyAdmin, git repos, Redis ports), that is broad-spectrum scanning, not a Magento-specific campaign.

---

## The noise-bracket subtraction rule

**Rule:** before labeling a cluster as campaign, subtract the baseline scanner-noise bracket for the CVE-era.

Sansec and other public researchers publish per-CVE noise brackets — the background volume of commercial-scanner and research-scanner traffic that hits a given vulnerable endpoint once public exploitation is known. The bracket is a range (e.g., "X to Y scanners per day against `/custom_options/` in the post-APSB25-94 era"), not a single number. If the cluster's observed activity falls inside the noise bracket, the campaign label is not warranted — the traffic is accounted for by scanners that would be there regardless of the specific operator the cluster represents.

Only clusters whose activity **exceeds** the noise bracket, **or** matches a signal profile the bracket does not cover (cross-CVE playbook, shared unique TTPs), earn the campaign label.

---

## Failure modes

**Treating every IP that touches `/custom_options/` as a campaign participant.** This is the most common over-attribution error in Magento-era incidents. Mass research scanners hit that endpoint routinely in the post-disclosure window. Narrow the cluster by:

1. Successful exploitation (HTTP 200 on the POST, not 404 or 403) — filters probing scanners.
2. Follow-up activity (more than one request from the IP within the incident window) — filters one-shot scanners.
3. Non-research ASN (IP not in a published research range) — filters institutional noise.

Only IPs that pass all three filters are candidates for campaign labeling. The rest are scanner noise and belong in the opportunistic bracket.

**Over-weighting a single signal.** Same UA across a cluster is a signal, but one signal is not a campaign. A campaign call requires signal-stacking — three or more of the campaign signals above co-occurring across the cluster. A single alignment (same UA, or same target path, or same timing) without the others is insufficient.

**Ignoring the cross-CVE correlation because only one CVE's log stream was reviewed.** If the incident was triaged from the Magento log tree only, the PolyShell → SessionReaper playbook signal may be hidden because the SessionReaper-side evidence is in `var/session/` and the REST access log, not the file-upload log. Widen the log scope before concluding an IP is single-CVE.

---

## Triage checklist

- [ ] Confirm `../ioc-aggregation/ip-clustering.md` has been applied — a cluster exists to classify
- [ ] Confirm `role-taxonomy.md` labels are attached to each IP in the cluster
- [ ] Confirm `timing-fingerprint.md` shape is assigned per IP
- [ ] Enumerate campaign signals present in the cluster; require three or more
- [ ] Enumerate opportunistic signals present; if any fire, reduce campaign confidence
- [ ] Check for cross-CVE correlation — do cluster IPs hit both `/custom_options/` and `/customer/address_file/upload`?
- [ ] Check target-path preference against known commercial-scanner signatures
- [ ] Check ASN membership against published research-network ranges
- [ ] Apply the noise-bracket subtraction — exclude activity that fits baseline scanner volume
- [ ] Apply the three-filter narrow on `/custom_options/`-only clusters before labeling
- [ ] If labeling campaign: name the signals that support the label and the noise-bracket calculation
- [ ] If labeling opportunistic: note the ASN / target-path / single-request evidence
- [ ] Hand the labeled cluster off to the IC brief — load [`../ic-brief-format/`](../ic-brief-format/) for IOC category assignment

---

## See also

- [role-taxonomy.md](role-taxonomy.md) — role labels required on cluster members
- [../ioc-aggregation/ip-clustering.md](../ioc-aggregation/ip-clustering.md) — clustering step that produces the input to this classifier
- [timing-fingerprint.md](timing-fingerprint.md) — aligned timing as a campaign signal
- [../apsb25-94/exploit-chain.md](../apsb25-94/exploit-chain.md) — PolyShell / APSB25-94 side of the cross-CVE correlation
- [../magento-attacks/admin-backdoor.md](../magento-attacks/admin-backdoor.md) — `accesson.php` directory-spray pattern used as a same-TTP signal
- [../ic-brief-format/](../ic-brief-format/) — downstream consumer of labeled clusters (IOC categorization)

<!-- adapted from beacon/skills/actor-attribution/campaign-vs-opportunistic.md (2026-04-23) — v2-reconciled -->
