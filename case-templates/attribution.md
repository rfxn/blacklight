<!-- writer: curator, when: on-hypothesis-revision (when kill chain advances), lifecycle: mutable, cap: 40 KB, src: case-layout.md §3 row 6, DESIGN.md §7.2 tree -->

# Attribution — kill chain

<!-- Five stanzas below follow the blacklight kill-chain vocabulary (upload/exec/persist/lateral/exfil). Curator fills each with **Evidence:** and **IoC:** sub-bullets as evidence lands. Grep anchor: `^## (Upload|Exec|Persist|Lateral|Exfil)$` must return 5. -->

## Upload

**Evidence:** <!-- TODO(curator): obs-<id> pointers -->
**IoC:** <!-- TODO(curator): file sha256 / URL / path -->

## Exec

**Evidence:** <!-- TODO(curator): obs-<id> pointers -->
**IoC:** <!-- TODO(curator): process argv / binary sha256 / syscall trace -->

## Persist

**Evidence:** <!-- TODO(curator): obs-<id> pointers -->
**IoC:** <!-- TODO(curator): cron entry / systemd unit / .bashrc line / .htaccess directive -->

## Lateral

**Evidence:** <!-- TODO(curator): obs-<id> pointers -->
**IoC:** <!-- TODO(curator): internal IP / SSH key / mount point / shared-credential pattern -->

## Exfil

**Evidence:** <!-- TODO(curator): obs-<id> pointers -->
**IoC:** <!-- TODO(curator): destination IP / domain / upload URL / data shape -->
