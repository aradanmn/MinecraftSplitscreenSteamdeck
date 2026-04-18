#!/usr/bin/env bash
# =============================================================================
# GitHub Rulesets Setup Script
# =============================================================================
# Configures branch protection and rulesets for the main repository via the
# GitHub REST API. Run this once after cloning, or whenever rules need reset.
#
# USAGE:
#   export GITHUB_TOKEN="ghp_yourPersonalAccessToken"
#   ./setup-rulesets.sh
#
# REQUIRED TOKEN SCOPES:
#   - repo (full) — needed to write branch protection and rulesets
#
# WHAT THIS SETS UP:
#   1. Main branch protection (classic)  — require PR, 1 approval, no force-push
#   2. Ruleset: branch naming            — enforce feat/fix/chore/docs/refactor/claude/ prefixes
#   3. Ruleset: commit messages          — conventional commit format
# =============================================================================

set -euo pipefail

OWNER="aradanmn"
REPO="minecraftsplitscreensteamdeck"
API="https://api.github.com"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[ERROR] GITHUB_TOKEN is not set."
    echo "        Export a PAT with 'repo' scope:"
    echo "        export GITHUB_TOKEN=ghp_yourToken"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required but not installed."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required but not installed."
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
CONTENT="Content-Type: application/json"

gh_api() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -fsSL -X "$method" \
            -H "$AUTH_HEADER" \
            -H "$CONTENT" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            --data "$body" \
            "$API$endpoint"
    else
        curl -fsSL -X "$method" \
            -H "$AUTH_HEADER" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$API$endpoint"
    fi
}

echo ""
echo "=== GitHub Rulesets Setup: $OWNER/$REPO ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Classic branch protection on main
#    - Require PRs with at least 1 approval
#    - Dismiss stale reviews when new commits are pushed
#    - Require conversation resolution before merge
#    - Require ShellCheck status check to pass
#    - No force-pushes, no branch deletion
#    - Linear history (squash/rebase only — no merge commits)
# ---------------------------------------------------------------------------

echo "[1/3] Applying classic branch protection to 'main'..."

gh_api PUT "/repos/$OWNER/$REPO/branches/main/protection" "$(jq -n '{
  required_status_checks: {
    strict: true,
    contexts: ["Lint shell scripts"]
  },
  enforce_admins: true,
  required_pull_request_reviews: {
    dismiss_stale_reviews: true,
    require_code_owner_reviews: false,
    required_approving_review_count: 1,
    require_last_push_approval: false
  },
  restrictions: null,
  required_linear_history: true,
  allow_force_pushes: false,
  allow_deletions: false,
  block_creations: false,
  required_conversation_resolution: true
}')" | jq '.url' -r

echo "[OK] Main branch protection applied."
echo ""

# ---------------------------------------------------------------------------
# 2. Ruleset: Branch naming convention
#    Applies to all branches EXCEPT main.
#    Allowed prefixes: feat/ fix/ chore/ docs/ refactor/ claude/ hotfix/ test/
# ---------------------------------------------------------------------------

echo "[2/3] Creating ruleset: branch naming convention..."

# Delete existing ruleset with same name if present (idempotent re-run)
existing=$(gh_api GET "/repos/$OWNER/$REPO/rulesets" | jq -r '.[] | select(.name == "Branch naming convention") | .id')
if [[ -n "$existing" ]]; then
    echo "      Deleting existing ruleset (id=$existing)..."
    gh_api DELETE "/repos/$OWNER/$REPO/rulesets/$existing" >/dev/null
fi

gh_api POST "/repos/$OWNER/$REPO/rulesets" "$(jq -n '{
  name: "Branch naming convention",
  target: "branch",
  enforcement: "active",
  conditions: {
    ref_name: {
      include: ["~ALL"],
      exclude: ["refs/heads/main"]
    }
  },
  rules: [
    {
      type: "ref_name",
      parameters: {
        patterns: [
          "feat/*",
          "fix/*",
          "chore/*",
          "docs/*",
          "refactor/*",
          "claude/*",
          "hotfix/*",
          "test/*"
        ]
      }
    }
  ]
}')" | jq '.id' -r | xargs -I{} echo "      Created ruleset id={}"

echo "[OK] Branch naming ruleset applied."
echo ""

# ---------------------------------------------------------------------------
# 3. Ruleset: Conventional commit messages
#    All commits to main (via PR squash/merge) must start with a conventional
#    commit type: feat|fix|chore|docs|refactor|perf|test|ci|build|revert
# ---------------------------------------------------------------------------

echo "[3/3] Creating ruleset: conventional commit messages..."

existing=$(gh_api GET "/repos/$OWNER/$REPO/rulesets" | jq -r '.[] | select(.name == "Conventional commits") | .id')
if [[ -n "$existing" ]]; then
    echo "      Deleting existing ruleset (id=$existing)..."
    gh_api DELETE "/repos/$OWNER/$REPO/rulesets/$existing" >/dev/null
fi

gh_api POST "/repos/$OWNER/$REPO/rulesets" "$(jq -n '{
  name: "Conventional commits",
  target: "branch",
  enforcement: "active",
  conditions: {
    ref_name: {
      include: ["refs/heads/main"],
      exclude: []
    }
  },
  rules: [
    {
      type: "commit_message_pattern",
      parameters: {
        name: "Conventional commit format",
        negate: false,
        operator: "regex",
        pattern: "^(feat|fix|chore|docs|refactor|perf|test|ci|build|revert)(\\([^)]+\\))?: .+"
      }
    }
  ]
}')" | jq '.id' -r | xargs -I{} echo "      Created ruleset id={}"

echo "[OK] Conventional commit ruleset applied."
echo ""
echo "=== Setup complete. ==="
echo ""
echo "Summary of rules now active on $OWNER/$REPO:"
echo "  main branch:"
echo "    - PRs required (1 approval, stale reviews dismissed)"
echo "    - ShellCheck CI must pass before merge"
echo "    - Conversation resolution required"
echo "    - Linear history enforced (squash/rebase only)"
echo "    - Force-push and deletion blocked"
echo "    - Admins are not exempt"
echo "  All other branches:"
echo "    - Must be named: feat/* fix/* chore/* docs/* refactor/* claude/* hotfix/* test/*"
echo "  Commits landing on main:"
echo "    - Must follow conventional commit format"
echo ""
