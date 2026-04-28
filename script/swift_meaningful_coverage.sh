#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THRESHOLD="${1:-95}"

export HOME="$ROOT_DIR/.tmp/home"
export XDG_CACHE_HOME="$ROOT_DIR/.tmp/home/Library/Caches"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.tmp/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.tmp/modulecache"

cd "$ROOT_DIR"

swift test --enable-code-coverage --package-path ui --disable-sandbox

CODECOV_PATH="$(
    swift test --package-path ui --show-codecov-path --disable-sandbox 2>/dev/null \
        | tail -n 1
)"

if [[ ! -f "$CODECOV_PATH" ]]; then
    echo "Coverage JSON not found at: $CODECOV_PATH" >&2
    exit 1
fi

# This gate intentionally excludes SwiftUI view bodies, app entry points,
# OS bridge wrappers, and other code where line coverage encourages shallow
# instantiation tests. It focuses on deterministic domain algorithms,
# planning, path building, hashing, indexing, and user-facing formatting.
MEANINGFUL_REGEX='/(BLAKE2bHasher|CopyPlanBuilder|DryRunPlanner|MediaDiscovery|PlanningPathBuilder|DeduplicationPlanner|PerceptualHash|UserFacingErrorMessage|RunHistoryIndexer|RunConfiguration\+Profiles|HybridOrganizerEngine|DedupeFeatureCache)\.swift$'

summary_json="$(
    jq --arg regex "$MEANINGFUL_REGEX" '
        def add_lines:
            reduce .[] as $x ({count:0, covered:0};
                .count += $x.summary.lines.count
                | .covered += $x.summary.lines.covered
            )
            | .percent = (if .count == 0 then 0 else (.covered / .count * 100) end);

        .data[0].files as $files
        | {
            raw: ($files | map(.summary.lines) | reduce .[] as $x ({count:0, covered:0};
                .count += $x.count
                | .covered += $x.covered
            ) | .percent = (.covered / .count * 100)),
            meaningful: ($files | map(select(.filename | test($regex))) | add_lines),
            files: ($files
                | map(select(.filename | test($regex)))
                | map({
                    path: (.filename | sub("^.*/ui/Sources/"; "ui/Sources/")),
                    percent: .summary.lines.percent,
                    covered: .summary.lines.covered,
                    count: .summary.lines.count
                })
                | sort_by(.percent))
        }
    ' "$CODECOV_PATH"
)"

raw_percent="$(jq -r '.raw.percent' <<<"$summary_json")"
meaningful_percent="$(jq -r '.meaningful.percent' <<<"$summary_json")"
meaningful_covered="$(jq -r '.meaningful.covered' <<<"$summary_json")"
meaningful_count="$(jq -r '.meaningful.count' <<<"$summary_json")"

printf 'Raw Swift coverage: %.2f%%\n' "$raw_percent"
printf 'Meaningful Swift coverage: %.2f%% (%s/%s lines)\n' \
    "$meaningful_percent" "$meaningful_covered" "$meaningful_count"
echo
echo "Meaningful files:"
jq -r '.files[] | "  \(.path): \(.percent | tostring)% (\(.covered)/\(.count))"' <<<"$summary_json"

awk -v actual="$meaningful_percent" -v threshold="$THRESHOLD" '
    BEGIN {
        if (actual + 0.000001 < threshold) {
            printf("Meaningful Swift coverage %.2f%% is below the %.2f%% threshold.\n", actual, threshold) > "/dev/stderr"
            exit 1
        }
    }
'
