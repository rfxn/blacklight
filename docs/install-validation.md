# Install validation — public install path verified

Captured 2026-04-25 against `https://github.com/rfxn/blacklight` `main` branch
HEAD (post-M11 P5 / pre-P14). Evidence reproduces in any clean container with
`curl` + `jq` available.

## Debian 12 (anvil container)

```
$ apt-get update -qq && apt-get install -qq -y curl jq
$ curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | bash
...
  2. Provision the managed agent + skills memstore (one-time per workspace):
       bl setup
  3. Start an investigation:
       bl observe --help
       bl consult "<case description>"

Uninstall:    curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/uninstall.sh | bash
Documentation: https://github.com/rfxn/blacklight

$ bl --version
bl 0.1.0

$ bl --help | head -8
bl — blacklight operator CLI

Usage: bl <command> [options]
       bl <command> --help      per-verb help

Commands:
  observe   Read-only evidence extraction (logs/fs/crons/htaccess/substrate)
  consult   Open / attach an investigation case via the curator agent

$ bl observe   # without API key
blacklight: preflight: ANTHROPIC_API_KEY not set
```

Result: `bl --version` reports `0.1.0`; binary present at `/usr/local/bin/bl`;
preflight on unseeded workspace correctly reports the missing-key bootstrap
message and exits non-zero.

## Rocky 9 (anvil container)

```
$ dnf install -y jq
$ curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | bash
...
$ bl --version
bl 0.1.0

$ bl --help | head -6
bl — blacklight operator CLI

Usage: bl <command> [options]
       bl <command> --help      per-verb help

Commands:

$ bl observe   # without API key
blacklight: preflight: ANTHROPIC_API_KEY not set
```

Result: identical to Debian 12.

## Verification command for re-checks

```bash
bl --version
# expect: bl 0.1.0
bl observe   # without setup → should error with bootstrap message
# expect: "preflight: ANTHROPIC_API_KEY not set"
```

## Scope

This validates the public `curl-pipe-bash` installer path on the two release
matrix targets. Full release matrix (`debian12 rocky9 ubuntu2404 centos7
rocky8 ubuntu2004`) is exercised separately in CI via the BATS suite —
`tests/10-install-paths.bats` covers the local install + roundtrip case.

Live-API round-trip evidence (curator session, custom-tool emit, memstore
writes) is captured separately in `docs/live-traces/CASE-2026-DEMO-trace.md`
and recorded into the M11 demo video.
