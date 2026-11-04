#!/usr/bin/env bash
#
# Personalizes a repository created from sfdx-project-template and applies the
# GitHub settings that templates don't copy (rulesets, security, merge options).
# Safe to re-run.
#
# Requires: gh (authenticated, with admin access to the repository), git, perl.

set -euo pipefail

TEMPLATE_REPO="daltonwilt/sfdx-project-template"
TEMPLATE_NAME="${TEMPLATE_REPO#*/}"
TEMPLATE_OWNER="${TEMPLATE_REPO%%/*}"

usage() {
  cat <<EOF
Usage: scripts/setup-repo.sh [--skip-files] [--skip-github]

  --skip-files   Don't rename the template's project names in local files
  --skip-github  Don't change any GitHub repository settings

The target repository is detected from the git remote. Set REPO=owner/name to override.
EOF
}

SKIP_FILES=false
SKIP_GITHUB=false
for arg in "$@"; do
  case "$arg" in
    --skip-files) SKIP_FILES=true ;;
    --skip-github) SKIP_GITHUB=true ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
NAME="${REPO#*/}"
OWNER="${REPO%%/*}"
FAILED=0

# Runs a command, printing a check mark or the command's error output.
step() {
  local desc=$1 out
  shift
  if out=$("$@" 2>&1); then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc" >&2
    echo "$out" | sed 's/^/      /' >&2
    FAILED=1
  fi
}

personalize_files() {
  echo "Personalizing files for $REPO"

  if [ "$REPO" = "$TEMPLATE_REPO" ]; then
    echo "  - This is the template repository itself; nothing to rename"
    return
  fi

  local files
  files=$(git grep -lI -e "$TEMPLATE_NAME" -- ':!scripts/setup-repo.sh' || true)
  if [ -n "$files" ]; then
    # shellcheck disable=SC2086
    perl -pi -e "s{\Q$TEMPLATE_REPO\E}{$OWNER/$NAME}g; s{\Q$TEMPLATE_NAME\E}{$NAME}g" $files
    echo "  ✓ Renamed $TEMPLATE_NAME to $NAME in:"
    echo "$files" | sed 's/^/      /'
  else
    echo "  - No template names left to rename"
  fi

  if [ "$OWNER" != "$TEMPLATE_OWNER" ] && grep -q "^\* @$TEMPLATE_OWNER\$" .github/CODEOWNERS; then
    perl -pi -e "s/^\* \@\Q$TEMPLATE_OWNER\E\$/* \@$OWNER/" .github/CODEOWNERS
    echo "  ✓ Set CODEOWNERS to @$OWNER"
    if [ "$(gh api "users/$OWNER" --jq .type)" = "Organization" ]; then
      echo "  ! $OWNER is an organization: CODEOWNERS needs a user or team, e.g. @$OWNER/team-name" >&2
    fi
  fi

  if grep -q '<!-- template:start -->' README.md; then
    perl -0pi -e 's/<!-- template:start -->.*?<!-- template:end -->\n\n//s' README.md
    echo "  ✓ Removed the template instructions from README.md"
  fi
}

configure_github() {
  local r="repos/$REPO" visibility
  visibility=$(gh api "$r" --jq .visibility)
  echo "Configuring GitHub settings for $REPO ($visibility)"

  step "Squash-only merging, auto-delete branches, wiki off" \
    gh api -X PATCH "$r" --silent \
      -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
      -F delete_branch_on_merge=true -F has_wiki=false \
      -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK

  step "Dependabot alerts" gh api -X PUT "$r/vulnerability-alerts" --silent
  step "Dependabot security updates" gh api -X PUT "$r/automated-security-fixes" --silent

  # Secret scanning and CodeQL are free on public repositories; private ones need GitHub Advanced Security.
  step "Secret scanning and push protection" \
    gh api -X PATCH "$r" --silent --input - <<'EOF'
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
EOF
  step "CodeQL default setup" \
    gh api -X PATCH "$r/code-scanning/default-setup" --silent -f state=configured -f query_suite=default

  if [ "$visibility" = "public" ]; then
    step "Private vulnerability reporting" gh api -X PUT "$r/private-vulnerability-reporting" --silent
    step "Require approval for first-time contributors' workflows" \
      gh api -X PUT "$r/actions/permissions/fork-pr-contributor-approval" --silent \
        -f approval_policy=first_time_contributors
  fi

  step "Read-only workflow token" \
    gh api -X PUT "$r/actions/permissions/workflow" --silent \
      -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

  step "Label: accessibility" \
    gh label create accessibility --repo "$REPO" --force \
      --color f143ab --description "Barrier affecting people with disabilities"

  # Status checks are the job names in .github/workflows/ci.yml; 15368 is the GitHub Actions app.
  local ruleset ruleset_id
  ruleset=$(cat <<'EOF'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "Lint", "integration_id": 15368 },
          { "context": "Unit tests", "integration_id": 15368 }
        ]
      }
    }
  ]
}
EOF
  )
  ruleset_id=$(gh api "$r/rulesets" --jq '.[] | select(.name == "Protect main") | .id')
  if [ -n "$ruleset_id" ]; then
    step "Ruleset \"Protect main\" (updated)" \
      gh api -X PUT "$r/rulesets/$ruleset_id" --silent --input - <<<"$ruleset"
  else
    step "Ruleset \"Protect main\" (created)" \
      gh api -X POST "$r/rulesets" --silent --input - <<<"$ruleset"
  fi
}

$SKIP_FILES || personalize_files
$SKIP_GITHUB || configure_github

echo
if [ "$FAILED" -ne 0 ]; then
  echo "Finished with errors; see the ✗ items above." >&2
  exit 1
fi
echo "Done."
if grep -q '\[INSERT CONTACT METHOD\]' CODE_OF_CONDUCT.md; then
  echo "Remember to replace [INSERT CONTACT METHOD] in CODE_OF_CONDUCT.md."
fi
if ! $SKIP_FILES && [ -n "$(git status --porcelain)" ]; then
  echo "Review the changes with 'git diff', then commit and push."
fi
