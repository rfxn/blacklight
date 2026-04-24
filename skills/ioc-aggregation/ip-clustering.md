# IP Clustering by Behavior

**Source authority:** Sansec campaign-tracking methodology across the SessionReaper follow-up <https://sansec.io/research/sessionreaper-exploitation> and PolyShell <https://sansec.io/research/magento-polyshell> writeups, grounded in MITRE ATT&CK T1071 Application Layer Protocol <https://attack.mitre.org/techniques/T1071/>. The clustering features below are a distillation of what those public writeups use to connect IPs to actors.

Clustering turns a list of 50 IPs into an answer to "how many distinct actors are we looking at?" The method is behavioral — IP address and geolocation are the weakest features in modern adversary infrastructure; traffic shape is the strongest. The curator writes clustering output to `bl-case/CASE-<id>/ip-clusters.md` after a sufficient volume of `observe.log_apache` evidence has compounded. Run [`../actor-attribution/role-taxonomy.md`](../actor-attribution/role-taxonomy.md) first — clustering on un-role-labeled IPs produces blurred feature space.

---

## Clustering features (operator priority order)

The order matters. Strong behavioral features at the top subsume weaker categorical features at the bottom. Start clustering at feature 1, refine with feature 2, confirm with 3 and 4, use 5 if available.

### 1. Target-path preferences

The set of URLs each IP touches, weighted by request count.

- IPs hitting `/custom_options/` + `/pub/media/` + `/customer/address_file/upload` cluster to PolyShell-era / SessionReaper actors.
- IPs hitting `/wp-admin/` + `/wp-login.php` + `/xmlrpc.php` cluster to WordPress-targeting actors.
- IPs that hit both cluster groups are diagnostic of a **broad opportunistic scanner**, not a targeted actor.
- Empty-intersection clusters (IPs whose target paths don't overlap with any other IP in the set) are usually noise — commercial scanners, research probes, or unique one-offs.

### 2. Polling interval fingerprint

The shape of the inter-request delta distribution (see [`../actor-attribution/timing-fingerprint.md`](../actor-attribution/timing-fingerprint.md) for the detailed treatment).

- ~21-second intervals with tight standard deviation → cron-like automation (`sleep N; curl` loop). Cluster strongly on this; the same interval value across IPs is a strong same-tooling signal.
- 10–60 minute irregular intervals with session structure → manual operator or sophisticated C2. Weaker clustering signal on the interval value alone; combine with target-path preference.

### 3. User-Agent + HTTP header shape

The full header set, not just UA.

- Identical UA + identical header ordering across IPs → same client library, strong same-tooling cluster signal.
- Different UA **per request** from the same IP is a diagnostic: **same IP rotating `python-requests/2.x` → `Go-http-client/1.1` → `curl/7.x` across consecutive requests is one operator running multiple tools, not multiple operators sharing an IP.** This is the commonly-missed case — analysts see the UA change and split the IP into multiple actors when they should merge the UAs into a single operator's toolbelt.
- Missing headers (no `Accept-Encoding`, no `Connection`) across a cluster are almost as diagnostic as a shared UA string — default-config scripting frameworks produce identical header gaps.

### 4. Request-body entropy and compression ratio

The payload size distribution and the ratio of base64-encoded payload length to decoded length.

- Uniform-length request bodies across an IP's sessions → single script generating them. Strong same-tooling signal.
- Varied-length bodies with a long-tail distribution → human-curated payloads or a toolchain that generates per-target payloads. Weaker same-tooling signal.
- Compression ratio (base64-decoded length / encoded length ≈ 0.75) is expected; anomalous ratios (≈ 0.55 or ≈ 0.90) indicate non-base64 encoding layered on top — same custom encoder across IPs is a strong cluster signal.

### 5. TLS fingerprint (JA3 / JA4)

If the edge captures TLS handshake fingerprints, this is the single strongest same-client signal available. Two IPs sharing a JA3/JA4 hash are running the same TLS library build — very often the same adversary toolkit. Absent edge capture, this feature is unavailable and the clustering proceeds on features 1–4.

---

## Clustering algorithm (operator-voice)

Don't over-automate. The workflow that produces reliable attribution is semi-manual:

1. Build a feature vector per IP across features 1–4 (and 5 if available). Keep the features as categorical buckets — e.g., target-path preference as a sorted tuple of URL prefixes, not a free-form URL string.
2. Sort IPs by feature-vector lexicographically. Adjacent rows with identical vectors are a trivial cluster.
3. For near-duplicate rows (Hamming distance ≤ 2 across the categorical features), manually inspect the top 10 candidate merges and decide.
4. Label each resulting cluster — `cluster-A` through `cluster-N` is fine; do not guess at actor names.

**Rule:** the semi-manual step in (3) catches the campaign-vs-opportunistic distinction that pure ML misses. Two IPs with Hamming distance 2 on raw features can be one actor using two tools or two actors accidentally targeting the same CVE. Only a human eyeballing session transcripts makes the call reliably.

---

## Cloud-hosted-IP caveat

Modern adversary infrastructure is cloud-ephemeral. Sansec has documented IPs involved in SessionReaper exploitation across multiple cloud providers simultaneously — <https://sansec.io/research/sessionreaper-exploitation> lists:

- 34.227.25.4
- 44.212.43.34
- 54.205.171.35
- 155.117.84.134
- 159.89.12.166

These IPs span AWS, DigitalOcean, and budget VPS ranges. The lesson: **treat /32 as the cluster unit, not /24 or /16.** Two IPs from the same /16 are not "close" in adversary terms — shared /16 is an accident of cloud allocation, not a signal of shared operator. Only ASN-level pivoting produces a meaningful coarser grain, and even then only on a known-bad ASN.

**Bulletproof-hosting call-out:** traffic from IPs on ASNs with a history of harboring malicious infrastructure (commonly maintained allowlists at the edge — SpamHaus DROP, FireHOL level-1 lists) clusters to campaign actors at a much higher rate than opportunistic traffic. A BH-ASN hit is not a cluster feature on its own, but it raises the prior on "this is a campaign" when combined with features 1–4.

---

## Failure modes

**IP-address-only clustering without behavioral features.** This produces nearest-neighbor noise: IPs land in the same subnet because of cloud allocation, not because they share an operator. The resulting clusters are meaningless. If the clustering methodology is "group by /24", the output is a geography report, not an attribution.

**Splitting one operator into multiple actors based on UA rotation.** Covered above; bears repeating. Tool rotation by a single operator is common — especially in the testing phase of a campaign where the operator checks whether each tool works against the target stack. Merge UAs under the IP before splitting.

**Clustering before roles are assigned.** Run `../actor-attribution/role-taxonomy.md` first. Clustering initial-compromise actors with C2 operators as if they were comparable produces a blurred feature space where nothing clusters cleanly. Restrict clustering to IPs that share a role, or include role as an additional feature at position 0.

---

## Triage checklist

- [ ] Confirm `role-taxonomy.md` has been applied — IPs are role-labeled before clustering
- [ ] Extract target-path preference per IP (sorted tuple of URL prefixes)
- [ ] Extract polling-interval fingerprint per IP (load [`../actor-attribution/timing-fingerprint.md`](../actor-attribution/timing-fingerprint.md))
- [ ] Extract UA + full header set per IP; flag mid-session UA rotations as single-operator signal
- [ ] Extract request-body length distribution per IP
- [ ] Extract JA3/JA4 per IP if edge-captured
- [ ] Sort IPs by feature vector, mark trivial clusters
- [ ] Manually adjudicate Hamming-distance ≤ 2 near-duplicate rows
- [ ] Apply cloud-IP /32 rule — do not merge on /24 or /16 alone
- [ ] Cross-reference BH-ASN lists; raise campaign-prior on hits
- [ ] Label clusters (`cluster-A`, `cluster-B`, ...) without guessing actor names
- [ ] Hand clusters off to [`../actor-attribution/campaign-vs-opportunistic.md`](../actor-attribution/campaign-vs-opportunistic.md) for final classification

---

## See also

- [../actor-attribution/role-taxonomy.md](../actor-attribution/role-taxonomy.md) — required prerequisite; role labels anchor the feature space
- [../actor-attribution/timing-fingerprint.md](../actor-attribution/timing-fingerprint.md) — polling-interval derivation for feature 2
- [../actor-attribution/campaign-vs-opportunistic.md](../actor-attribution/campaign-vs-opportunistic.md) — classification of the resulting clusters
- [../linux-forensics/post-to-shell-correlation.md](../linux-forensics/post-to-shell-correlation.md) — per-IP request sequencing that produces the target-path-preference feature

<!-- adapted from beacon/skills/actor-attribution/ip-clustering-by-behavior.md (2026-04-23) — v2-reconciled -->
