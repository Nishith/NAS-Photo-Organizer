#!/usr/bin/env bash
#
# Verifies that every bullet under AGENTS.md's "## Safety Invariants" section
# has at least one test method tagged with a matching AGENTS-INVARIANT marker.
#
# How to tag a test:
#
#     // AGENTS-INVARIANT: 7
#     func testRevertDeletesOnlyWhenHashStillMatches() throws { ... }
#
# Where `7` is the (1-indexed) bullet number under "## Safety Invariants" in
# AGENTS.md. The check is strictly structural: it never reads the test body.
# It enforces that prose claims and code coverage stay aligned, so a future
# change to a safety invariant cannot silently ship without a corresponding
# test update.
#
# The marker format is also intentionally human-grep-able from inside an IDE:
# `// AGENTS-INVARIANT:` jumps to the test surface for the invariant.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_MD="$ROOT_DIR/AGENTS.md"
TESTS_DIR="$ROOT_DIR/ui/Tests"

if [[ ! -f "$AGENTS_MD" ]]; then
    echo "AGENTS.md not found at $AGENTS_MD" >&2
    exit 2
fi

# Extract bullets under "## Safety Invariants" up to the next "##" header.
# Bash 3.2 (macOS default) lacks `mapfile`, so we read line-by-line.
bullets=()
while IFS= read -r line; do
    bullets+=("$line")
done < <(
    awk '
        /^## Safety Invariants/ { capturing = 1; next }
        /^## / && capturing { exit }
        capturing && /^- / {
            sub(/^- /, "")
            print
        }
    ' "$AGENTS_MD"
)

if (( ${#bullets[@]} == 0 )); then
    echo "No bullets found under '## Safety Invariants' in AGENTS.md" >&2
    exit 2
fi

# Grep ALL AGENTS-INVARIANT markers across the test tree once.
marker_lines="$(grep -RInE '// AGENTS-INVARIANT:[[:space:]]*[0-9]+' "$TESTS_DIR" || true)"

missing=0
echo "Checking ${#bullets[@]} safety invariants…"
for i in "${!bullets[@]}"; do
    n=$((i + 1))
    bullet="${bullets[i]}"
    # First sentence only, for readable output.
    summary="$(printf '%s' "$bullet" | head -c 100)"
    refs=""
    if [[ -n "$marker_lines" ]]; then
        refs="$(printf '%s\n' "$marker_lines" \
            | grep -E "AGENTS-INVARIANT:[[:space:]]*${n}([^0-9]|$)" \
            | awk -F: '{print $1}' \
            | sort -u || true)"
    fi
    if [[ -z "$refs" ]]; then
        printf '✗ INV-%02d  %s\n' "$n" "$summary"
        printf '         (no test tagged // AGENTS-INVARIANT: %d)\n' "$n"
        missing=$((missing + 1))
    else
        count="$(printf '%s\n' "$refs" | wc -l | tr -d ' ')"
        printf '✓ INV-%02d  %s\n' "$n" "$summary"
        printf '         (%s test file(s))\n' "$count"
    fi
done

echo
if (( missing > 0 )); then
    echo "✗ ${missing} of ${#bullets[@]} invariants have no test coverage." >&2
    echo "  Tag at least one test method per missing invariant with:" >&2
    echo "      // AGENTS-INVARIANT: <bullet-number>" >&2
    echo "  See $(basename "${BASH_SOURCE[0]}") for details." >&2
    exit 1
fi
echo "✓ All ${#bullets[@]} safety invariants have at least one tagged test."
