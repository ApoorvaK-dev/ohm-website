#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════
# ohm-push.sh — bundled inside every ohm-dev-*.zip
#
# What it does (fully automatic after first run):
#   1. Reads config from ~/.ohm-push-config (token + username)
#      If missing, asks once and saves.
#   2. Installs git / curl / jq via pkg if missing
#   3. Inits git repo at ~/ohm if needed, sets remote
#   4. Stages all changes, commits with zip name + timestamp
#   5. Pushes to github.com/<user>/ohm (main branch)
#   6. Triggers GitHub Actions workflows via API
#   7. Polls CI status and prints result
#   8. Logs everything to ~/ohm-push.log
#
# Usage (from inside ~/ohm after unzipping):
#   bash ~/ohm/ohm-push.sh
#
# Or copy to ~ first:
#   cp ~/ohm/ohm-push.sh ~/ && bash ~/ohm-push.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Identity ──────────────────────────────────────────────────────
SCRIPT_VERSION="1.0"
REPO_DIR="$HOME/ohm-website"
LOG_FILE="$HOME/ohm-push.log"
CONFIG_FILE="$HOME/.ohm-push-config"

# ── Colours ───────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
B='\033[0;34m' W='\033[1m'   D='\033[2m' N='\033[0m'

# ── Logging (to screen AND file simultaneously) ───────────────────
_ts()  { date '+%H:%M:%S'; }
log()  { printf "${B}▸${N} %s\n" "$1"; printf "[%s] %s\n"   "$(_ts)" "$1"   >> "$LOG_FILE"; }
ok()   { printf "${G}✓${N} %s\n" "$1"; printf "[%s] ✓ %s\n" "$(_ts)" "$1"   >> "$LOG_FILE"; }
warn() { printf "${Y}⚠${N} %s\n" "$1"; printf "[%s] ⚠ %s\n" "$(_ts)" "$1"   >> "$LOG_FILE"; }
err()  { printf "${R}✗${N} %s\n" "$1"; printf "[%s] ✗ %s\n" "$(_ts)" "$1"   >> "$LOG_FILE"; }
die()  { err "$1"; printf "\n${R}${W}Fatal — see %s${N}\n\n" "$LOG_FILE"; exit 1; }
bar()  { printf "\n${W}%s${N}\n%s\n" "$1" "────────────────────────────────"; }

# ── Log session header ────────────────────────────────────────────
{
  printf "\n%s\n" "════════════════════════════════════════"
  printf "  ohm-push v%s — %s\n" "$SCRIPT_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "%s\n" "════════════════════════════════════════"
} >> "$LOG_FILE"

clear
printf "\n${W}  Ω  ohm-push${N}\n\n"

# ═══════════════════════════════════════════════════════════════════
# STEP 1 — Config (token + username, saved after first run)
# ═══════════════════════════════════════════════════════════════════
bar "1 — Config"

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" << CFGEOF
GITHUB_TOKEN=${GITHUB_TOKEN}
GITHUB_USER=${GITHUB_USER}
CFGEOF
  chmod 600 "$CONFIG_FILE"
  ok "Config saved → $CONFIG_FILE"
}

load_config

if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_USER:-}" ]; then
  printf "\n  First run — enter GitHub credentials.\n"
  printf "  These are saved to %s and never asked again.\n\n" "$CONFIG_FILE"

  if [ -z "${GITHUB_USER:-}" ]; then
    read -r -p "  GitHub username: " GITHUB_USER
  fi

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    printf "\n  Token needs scopes: ${W}repo${N}  ${W}workflow${N}\n"
    printf "  Create one at: https://github.com/settings/tokens/new\n\n"
    read -r -p "  GitHub token (ghp_...): " GITHUB_TOKEN
  fi

  [ -z "$GITHUB_USER" ]  && die "No username provided"
  [ -z "$GITHUB_TOKEN" ] && die "No token provided"

  save_config
else
  ok "Config loaded: @${GITHUB_USER}"
fi

export GITHUB_TOKEN GITHUB_USER

# ═══════════════════════════════════════════════════════════════════
# STEP 2 — Dependencies
# ═══════════════════════════════════════════════════════════════════
bar "2 — Dependencies"

for DEP in git curl jq; do
  if ! command -v "$DEP" &>/dev/null; then
    log "Installing $DEP..."
    pkg install -y -q "$DEP" 2>>"$LOG_FILE" || die "Failed to install $DEP"
    ok "$DEP installed"
  else
    ok "$DEP ready"
  fi
done

# ═══════════════════════════════════════════════════════════════════
# STEP 3 — Verify GitHub auth
# ═══════════════════════════════════════════════════════════════════
bar "3 — Auth"

log "Verifying token..."
AUTH_RESP=$(curl -sf \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/user" 2>>"$LOG_FILE") || die "GitHub API unreachable"

VERIFIED_USER=$(printf '%s' "$AUTH_RESP" | jq -r '.login' 2>/dev/null)
[ -z "$VERIFIED_USER" ] || [ "$VERIFIED_USER" = "null" ] && die "Auth failed — token may be expired. Delete $CONFIG_FILE and re-run."
ok "Authenticated as @${VERIFIED_USER}"

# Auto-correct username if needed
if [ "$VERIFIED_USER" != "$GITHUB_USER" ]; then
  warn "Username mismatch: config=${GITHUB_USER}, token=${VERIFIED_USER} — using token value"
  GITHUB_USER="$VERIFIED_USER"
  save_config
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 4 — Git init / remote
# ═══════════════════════════════════════════════════════════════════
bar "4 — Git"

[ -d "$REPO_DIR" ] || die "Repo dir not found: $REPO_DIR — unzip the ohm-dev-*.zip to ~/ohm first"
cd "$REPO_DIR"

# Build authenticated remote URL from known-clean variables
REMOTE_URL="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/ohm.git"

if [ ! -d ".git" ]; then
  log "Initialising git repo..."
  git init -q 2>>"$LOG_FILE"
  git config user.email "ohm-push@local"
  git config user.name "Ohm Push"
  git remote add origin "$REMOTE_URL"
  ok "Git repo initialised"
else
  # Always refresh remote URL (token may have rotated)
  git remote set-url origin "$REMOTE_URL" 2>>"$LOG_FILE" || \
    git remote add origin "$REMOTE_URL"   2>>"$LOG_FILE"
  ok "Remote URL refreshed"
fi

# Abort any in-progress rebase/merge left from a previous failed run
if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
  warn "In-progress rebase detected — aborting..."
  git rebase --abort 2>>"$LOG_FILE" || true
  ok "Rebase aborted"
fi
if [ -f ".git/MERGE_HEAD" ]; then
  warn "In-progress merge detected — aborting..."
  git merge --abort 2>>"$LOG_FILE" || true
  ok "Merge aborted"
fi

# Ensure on main
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [ "$CURRENT_BRANCH" != "main" ]; then
  log "Switching to main..."
  git checkout -B main 2>>"$LOG_FILE" || warn "Branch switch had warnings"
fi
ok "On branch: main"

# ═══════════════════════════════════════════════════════════════════
# STEP 5 — Detect zip name for commit message
# ═══════════════════════════════════════════════════════════════════
bar "5 — Commit"

# Detect zip name from TASKS.md or fall back to timestamp
ZIP_NAME=""
if [ -f "TASKS.md" ]; then
  ZIP_NAME=$(grep -oP 'ohm-dev-[a-z][0-9]' TASKS.md 2>/dev/null | tail -1 || echo "")
fi
if [ -z "$ZIP_NAME" ]; then
  ZIP_NAME="ohm-dev-$(date '+%Y%m%d-%H%M')"
fi

# Resolve any leftover conflict markers by keeping our version
CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
if [ -n "$CONFLICTED" ]; then
  warn "Conflict markers found — resolving by keeping local version..."
  printf '%s
' "$CONFLICTED" | while read -r FILE; do
    git checkout --ours -- "$FILE" 2>>"$LOG_FILE" || true
    log "  Resolved: $FILE"
  done
  ok "All conflicts resolved (kept local)"
fi

# Stage everything
log "Staging all changes..."
git add -A 2>>"$LOG_FILE" || die "git add failed"

# Count changes
CHANGED=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')

if git diff --cached --quiet 2>/dev/null; then
  warn "Nothing to commit — working tree is clean"
  SKIP_PUSH=true
else
  SKIP_PUSH=false

  # Build rich commit message
  CHANGED_LIST=$(git diff --cached --name-only 2>/dev/null | head -15 | sed 's/^/  - /')
  COMMIT_MSG="push(${ZIP_NAME}): ${CHANGED} file(s)

Source: ${ZIP_NAME}
Pushed: $(date '+%Y-%m-%d %H:%M:%S')
By: @${GITHUB_USER}

Files changed (first 15):
${CHANGED_LIST}"

  log "Committing ${CHANGED} file(s)..."
  git commit -q -m "$COMMIT_MSG" 2>>"$LOG_FILE" || die "git commit failed — check $LOG_FILE"
  ok "Committed: ${ZIP_NAME} (${CHANGED} files)"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 6 — Push
# ═══════════════════════════════════════════════════════════════════
bar "6 — Push"

if [ "${SKIP_PUSH}" = "true" ]; then
  warn "Skipping push (nothing committed)"
else
  log "Pushing to github.com/${GITHUB_USER}/ohm..."

  PUSH_OUT=$(git push -u origin main --force 2>&1) || {
    printf '%s\n' "$PUSH_OUT" >> "$LOG_FILE"
    die "Push failed: $(printf '%s' "$PUSH_OUT" | head -3)"
  }

  printf '%s\n' "$PUSH_OUT" >> "$LOG_FILE"
  ok "Pushed → github.com/${GITHUB_USER}/ohm-website"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 7 — Actions
# ═══════════════════════════════════════════════════════════════════
bar "7 — Actions"
ok "Triggered automatically by push"
log "  https://github.com/${GITHUB_USER}/ohm-website/actions"

# ═══════════════════════════════════════════════════════════════════
# STEP 8 — Poll CI status
# ═══════════════════════════════════════════════════════════════════
bar "8 — CI Status"

# Capture the SHA of the commit we just pushed
HEAD_SHA=$(cd "$REPO_DIR" && git rev-parse HEAD 2>/dev/null || echo "")
log "Commit SHA: ${HEAD_SHA:0:12}..."
log "Waiting 20s for GitHub to register runs..."
sleep 20

RUNS_RESP=$(curl -s \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${GITHUB_USER}/ohm-website/actions/runs?branch=main&per_page=20" \
  2>>"$LOG_FILE") || RUNS_RESP="{}"

# Extract runs for this exact SHA
MATCHING=$(printf '%s' "$RUNS_RESP" | \
  jq -r --arg sha "$HEAD_SHA" \
  '.workflow_runs[] | select(.head_sha == $sha) |
   "\(.status | ascii_upcase) \(.name) \(.conclusion // "in_progress")"' \
  2>/dev/null || echo "")

if [ -n "$MATCHING" ]; then
  printf '%s\n' "$MATCHING" | while IFS= read -r LINE; do
    NAME=$(printf '%s' "$LINE" | cut -d' ' -f2-)
    STATUS=$(printf '%s' "$LINE" | cut -d' ' -f1)
    CONCLUSION=$(printf '%s' "$LINE" | awk '{print $NF}')
    case "$CONCLUSION" in
      success)     ok  "$NAME" ;;
      failure|error) err "$NAME [failed]" ;;
      cancelled)   warn "$NAME [cancelled]" ;;
      in_progress) log "$NAME [running...]" ;;
      *)           log "$NAME [$STATUS]" ;;
    esac
  done
else
  warn "No runs found for SHA ${HEAD_SHA:0:12} yet"
  warn "Runs may still be queuing — check:"
  log "  https://github.com/${GITHUB_USER}/ohm-website/actions"
fi

# ═══════════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════════

# Count errors from THIS session only (lines after the last session header)
SESSION_LINE=$(grep -n "ohm-push v" "$LOG_FILE" 2>/dev/null | tail -1 | cut -d: -f1 | tr -d "[:space:]")
SESSION_LINE=${SESSION_LINE:-1}
ERROR_COUNT=$(tail -n +"$SESSION_LINE" "$LOG_FILE" 2>/dev/null | grep -c " ✗ " 2>/dev/null | tr -d "[:space:]")
ERROR_COUNT=${ERROR_COUNT:-0}

printf "\n${G}${W}  ✓  Done.${N}\n\n"
printf "  Commit:  %s\n"       "$ZIP_NAME"
printf "  Repo:    %s\n"       "https://github.com/${GITHUB_USER}/ohm-website"
printf "  Actions: %s\n"       "https://github.com/${GITHUB_USER}/ohm-website/actions"
printf "  Log:     %s\n"       "$LOG_FILE"

if [ "$ERROR_COUNT" -gt 0 ]; then
  printf "\n${Y}  ⚠ %s error(s) this session:${N}\n" "$ERROR_COUNT"
  tail -n +"$SESSION_LINE" "$LOG_FILE" | grep " ✗ " | tail -5 | while read -r LINE; do
    printf "  ${R}%s${N}\n" "$LINE"
  done
fi

printf "\n"
