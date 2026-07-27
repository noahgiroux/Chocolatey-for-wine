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

mapfile -t tree_changing_commits < <(
    while read -r commit; do
        if ! git diff-tree --quiet --no-commit-id "${commit}^1" "$commit" --; then
            printf '%s\n' "$commit"
        fi
    done < <(git rev-list --reverse "${local_ref}..${upstream_ref}")
)

# Preserve the existing content-equivalence allowance for genuinely divergent
# tips, but do not let a change followed by a revert disappear when local is
# still at the merge-base tree.
merge_base=$(git merge-base "$local_ref" "$upstream_ref")
if git diff --quiet "${local_ref}^{tree}" "${upstream_ref}^{tree}" && {
    [[ "${#tree_changing_commits[@]}" -eq 0 ]] || ! git diff --quiet "${local_ref}^{tree}" "${merge_base}^{tree}";
}; then
    write_summary 'Unseen commits have an identical tree since merge-base; no source drift.'
    printf '%s\n' 'Unseen commits have an identical tree since merge-base; no source drift.'
    exit 0
fi

write_summary ''
write_summary 'Tree-changing unseen commits:'
write_summary '```text'
for commit in "${tree_changing_commits[@]}"; do
    git show -s --format='%h %s' "$commit" >> "${summary_file:-/dev/null}"
done
write_summary '```'
write_summary ''
write_summary 'All unseen commits:'
write_summary '```text'
git log --oneline --no-decorate "${local_ref}..${upstream_ref}" >> "${summary_file:-/dev/null}"
write_summary '```'
printf '::error title=Canonical upstream changed::%s unseen commit(s) include tree-changing unseen commit(s); need review\n' "$unseen" >&2
exit 1
