#!/usr/bin/env bash
set -euo pipefail

local_ref=${1:-HEAD}
upstream_ref=${2:-canonical-upstream/main}
summary_file=${GITHUB_STEP_SUMMARY:-}

write_summary() {
    if [[ -n "$summary_file" ]]; then
        printf '%s\n' "$1" >> "$summary_file"
    fi
}

unseen=$(git rev-list --count "${local_ref}..${upstream_ref}")
write_summary '## Canonical upstream status'
write_summary ''
write_summary "Unseen commits: $unseen"

if [[ "$unseen" -eq 0 ]]; then
    write_summary 'No unseen canonical upstream commits.'
    printf '%s\n' 'No unseen canonical upstream commits.'
    exit 0
fi

merge_base=$(git merge-base "$local_ref" "$upstream_ref")
if git diff --quiet "${merge_base}^{tree}" "${upstream_ref}^{tree}"; then
    write_summary 'Unseen commits have an identical tree since merge-base; no source drift.'
    printf '%s\n' 'Unseen commits have an identical tree since merge-base; no source drift.'
    exit 0
fi

write_summary ''
write_summary '```text'
git log --oneline --no-decorate "${local_ref}..${upstream_ref}" >> "${summary_file:-/dev/null}"
write_summary '```'
printf '::error title=Canonical upstream changed::%s PietJankbal commit(s) need review\n' "$unseen" >&2
exit 1
