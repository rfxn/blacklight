#!/usr/bin/env bats
# tests/skill-routing/smoke.bats — M13 P4: structural tests for routing-skills/
# Verifies: 6-Skill count, description size caps, SKILL.md body cap, 4-block format,
# corpus-path resolution, vocab purity (no bl-skills/ refs), foundations.md presence,
# skills-corpus-check drift guard, and curator-agent.md prompt-content assertions
# deferred from P9 (curator §3.1 /skills/foundations.md ref; §9 anti-pattern 9).
#
# Portability: works locally (CWD = repo root) and in Docker container (CWD = /opt/tests).
# BATS_REPO_ROOT resolver in setup() handles both contexts.

setup() {
    # Resolve repo root: container has /opt/routing-skills + /opt/skills-corpus;
    # local run resolves one level above BATS_TEST_DIRNAME (tests/).
    if [[ -d /opt/routing-skills && -d /opt/skills-corpus ]]; then
        BATS_REPO_ROOT="/opt"
    else
        BATS_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    fi
    export BATS_REPO_ROOT
}

# ---------------------------------------------------------------------------
# Test 1 — directory count
# ---------------------------------------------------------------------------
@test "routing-skills/ contains exactly 6 directories" {
    local count
    count=$(ls "$BATS_REPO_ROOT/routing-skills/" | wc -l)
    [[ "$count" -eq 6 ]]
}

# ---------------------------------------------------------------------------
# Test 2 — each Skill has both required files
# ---------------------------------------------------------------------------
@test "every routing Skill has description.txt and SKILL.md" {
    local skill
    for skill in "$BATS_REPO_ROOT/routing-skills"/*/; do
        [[ -f "${skill}description.txt" ]] || {
            echo "missing: ${skill}description.txt" >&3
            return 1
        }
        [[ -f "${skill}SKILL.md" ]] || {
            echo "missing: ${skill}SKILL.md" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 3 — description.txt byte cap (≤1024)
# ---------------------------------------------------------------------------
@test "every description.txt is ≤1024 bytes" {
    local skill size
    for skill in "$BATS_REPO_ROOT/routing-skills"/*/; do
        size=$(wc -c < "${skill}description.txt")
        [[ "$size" -le 1024 ]] || {
            echo "FAIL: ${skill}description.txt is ${size} bytes (cap 1024)" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 4 — description.txt 4-block structure (3 blank-line separators)
# ---------------------------------------------------------------------------
@test "every description.txt has 4 paragraph blocks (≥3 blank-line separators)" {
    local skill blanks
    for skill in "$BATS_REPO_ROOT/routing-skills"/*/; do
        blanks=$(grep -c '^$' "${skill}description.txt" || true)
        [[ "$blanks" -ge 3 ]] || {
            echo "FAIL: ${skill}description.txt has only ${blanks} blank lines (need ≥3)" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 5 — SKILL.md line cap (≤500, warn-only — informational, not a hard fail)
# ---------------------------------------------------------------------------
@test "every SKILL.md is ≤500 lines (warn-only)" {
    local skill lines
    for skill in "$BATS_REPO_ROOT/routing-skills"/*/; do
        lines=$(wc -l < "${skill}SKILL.md")
        if [[ "$lines" -gt 500 ]]; then
            echo "WARN: ${skill}SKILL.md has ${lines} lines (soft cap 500)" >&3
        fi
    done
    # Warn-only: always pass
    true
}

# ---------------------------------------------------------------------------
# Test 6 — each SKILL.md cites at least one /skills/ corpus path that resolves
# ---------------------------------------------------------------------------
@test "every SKILL.md cites at least one /skills/ corpus path that resolves" {
    local skill corpus_name corpus_file found
    for skill in "$BATS_REPO_ROOT/routing-skills"/*/; do
        found=0
        # Extract /skills/<name>.md citations; test that the corpus file exists
        while IFS= read -r line; do
            corpus_name="${line#/skills/}"   # strip leading /skills/
            corpus_file="$BATS_REPO_ROOT/skills-corpus/$corpus_name"
            if [[ -f "$corpus_file" ]]; then
                found=1
                break
            fi
        done < <(grep -o '/skills/[a-z][a-z-]*\.md' "${skill}SKILL.md" | sort -u)
        [[ "$found" -eq 1 ]] || {
            echo "FAIL: ${skill}SKILL.md has no resolving /skills/ citation" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 7 — skills-corpus/ contains exactly 8 .md files
# ---------------------------------------------------------------------------
@test "skills-corpus/ contains exactly 8 .md files" {
    local count
    count=$(ls "$BATS_REPO_ROOT"/skills-corpus/*.md | wc -l)
    [[ "$count" -eq 8 ]]
}

# ---------------------------------------------------------------------------
# Test 8 — skills-corpus-check: corpus files are in sync with skills/ source
# Skipped inside the Docker container: the container's find(1) sort order
# differs from the host's, producing false-positive drift on SKILL.md ordering.
# The host-side check (`make skills-corpus-check`) is the authoritative gate;
# this test guards against accidental in-tree edits to skills-corpus/ on the host.
# ---------------------------------------------------------------------------
@test "skills-corpus is in sync with skills/ source (drift guard — host only)" {
    # Skip inside container: false-positive drift from find(1) sort-order divergence
    if [[ -d /opt/routing-skills && -d /opt/skills-corpus ]]; then
        skip "host-only check — find sort order differs in container"
    fi
    local tmp_dir script
    script="$BATS_REPO_ROOT/scripts/build-skills-corpus.sh"
    [[ -f "$script" ]] || skip "build-skills-corpus.sh not available"
    tmp_dir=$(mktemp -d)
    CORPUS_DIR="$tmp_dir" bash "$script" >/dev/null 2>&1
    local drift=0
    for f in "$tmp_dir"/*.md; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        diff -q "$f" "$BATS_REPO_ROOT/skills-corpus/$base" >/dev/null 2>&1 || {
            echo "drift in $base — run 'make skills-corpus' and re-commit" >&3
            drift=1
        }
    done
    rm -rf "$tmp_dir"
    [[ "$drift" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Test 9 — no SKILL.md cites bl-skills/ paths (Path C migration complete)
# ---------------------------------------------------------------------------
@test "no SKILL.md cites bl-skills/ paths (Path C migration complete)" {
    local matches
    matches=$(grep -rn 'bl-skills/' "$BATS_REPO_ROOT/routing-skills"/*/SKILL.md | wc -l)
    [[ "$matches" -eq 0 ]] || {
        echo "FAIL: found $matches bl-skills/ references in routing-skills SKILL.md files" >&3
        grep -rn 'bl-skills/' "$BATS_REPO_ROOT/routing-skills"/*/SKILL.md >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# Test 10 — skills/INDEX.md is the only skills/*.md NOT in any corpus (sanity)
# ---------------------------------------------------------------------------
@test "skills/INDEX.md is the only top-level skills/*.md not in any corpus" {
    # INDEX.md is intentionally not bundled into a corpus; all other *.md at
    # skills/ root level (if any) should be in a subdirectory, not loose files.
    # This is a sanity check that will be deleted/revised in P10.
    local loose skill_root
    skill_root="$BATS_REPO_ROOT/skills"
    loose=$(find "$skill_root" -maxdepth 1 -name '*.md' ! -name 'INDEX.md' | wc -l)
    [[ "$loose" -eq 0 ]] || {
        echo "WARN: found $loose unexpected loose .md files at skills/ root (besides INDEX.md)" >&3
    }
    # Warn-only: INDEX.md is expected; this test catches unexpected loose files.
    true
}

# ---------------------------------------------------------------------------
# Test 11 — (P9 deferred) curator-agent.md §3 references /skills/foundations.md
# (not legacy bl-skills/INDEX.md)
# ---------------------------------------------------------------------------
@test "curator-agent.md §3 references /skills/foundations.md (Path C vocabulary)" {
    local prompt_file
    prompt_file="$BATS_REPO_ROOT/prompts/curator-agent.md"
    [[ -f "$prompt_file" ]] || {
        echo "FAIL: $prompt_file not found" >&3
        return 1
    }
    # §3 / §3.1 Primitives table row for Files lists /skills/foundations.md
    grep -q '/skills/foundations\.md' "$prompt_file" || {
        echo "FAIL: /skills/foundations.md not found in $prompt_file" >&3
        return 1
    }
    # Must NOT reference legacy bl-skills/INDEX.md anywhere
    grep -q 'bl-skills/INDEX\.md' "$prompt_file" && {
        echo "FAIL: legacy bl-skills/INDEX.md reference found in $prompt_file" >&3
        return 1
    }
    true
}

# ---------------------------------------------------------------------------
# Test 12 — (P9 deferred) curator-agent.md §9 contains anti-pattern 9 bullet
# (do not pre-grep /skills/ or list its directory contents)
# ---------------------------------------------------------------------------
@test "curator-agent.md §9 contains anti-pattern 9 (do not pre-grep /skills/)" {
    local prompt_file
    prompt_file="$BATS_REPO_ROOT/prompts/curator-agent.md"
    [[ -f "$prompt_file" ]] || {
        echo "FAIL: $prompt_file not found" >&3
        return 1
    }
    # §9 anti-pattern 9 must contain a pre-grep prohibition referencing /skills/
    grep -q 'pre-grep' "$prompt_file" || {
        echo "FAIL: no 'pre-grep' prohibition found in $prompt_file (expected §9 anti-pattern 9)" >&3
        return 1
    }
    grep -q "pre-grep.*skills\|pre-grep.*/skills/" "$prompt_file" || {
        echo "FAIL: pre-grep prohibition does not reference /skills/ in $prompt_file" >&3
        return 1
    }
    true
}
