#!/bin/bash
# Compound Product - Full Pipeline
# Reads a report, picks #1 priority, creates PRD + tasks, runs loop, creates PR
#
# Usage: ./auto-compound.sh [--dry-run]
#
# Requirements:
# - amp or claude CLI installed and authenticated
# - gh CLI installed and authenticated
# - jq installed
# - ANTHROPIC_API_KEY environment variable set

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/compound.config.json"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
  exit 1
}

# Load config
if [ ! -f "$CONFIG_FILE" ]; then
  error "Config file not found: $CONFIG_FILE. Run install.sh first or copy config.example.json"
fi

TOOL=$(jq -r '.tool // "amp"' "$CONFIG_FILE")
REPORTS_DIR=$(jq -r '.reportsDir // "./reports"' "$CONFIG_FILE")
OUTPUT_DIR=$(jq -r '.outputDir // "./scripts/compound"' "$CONFIG_FILE")
MAX_ITERATIONS=$(jq -r '.maxIterations // 25' "$CONFIG_FILE")
BRANCH_PREFIX=$(jq -r '.branchPrefix // "compound/"' "$CONFIG_FILE")
ANALYZE_COMMAND=$(jq -r '.analyzeCommand // ""' "$CONFIG_FILE")
QUALITY_CHECKS=$(jq -r '.qualityChecks // ["echo No quality checks configured"]' "$CONFIG_FILE")

# Resolve paths
REPORTS_DIR="$PROJECT_ROOT/$REPORTS_DIR"
OUTPUT_DIR="$PROJECT_ROOT/$OUTPUT_DIR"
TASKS_DIR="$PROJECT_ROOT/tasks"

# Check requirements
command -v "$TOOL" >/dev/null 2>&1 || error "$TOOL CLI not found"
command -v gh >/dev/null 2>&1 || error "gh CLI not found. Install with: brew install gh"
command -v jq >/dev/null 2>&1 || error "jq not found. Install with: brew install jq"
# Only require ANTHROPIC_API_KEY if using default analyze script
if [ -z "$ANALYZE_COMMAND" ]; then
  [ -n "$ANTHROPIC_API_KEY" ] || error "ANTHROPIC_API_KEY not set"
fi

cd "$PROJECT_ROOT"

# Step 1: Find most recent report
log "Step 1: Finding most recent report..."
git pull origin main 2>/dev/null || true

LATEST_REPORT=$(ls -t "$REPORTS_DIR"/*.md 2>/dev/null | head -1)
[ -f "$LATEST_REPORT" ] || error "No reports found in $REPORTS_DIR"
REPORT_NAME=$(basename "$LATEST_REPORT")
log "Using report: $REPORT_NAME"

# Step 2: Analyze report
log "Step 2: Analyzing report to pick #1 actionable priority..."

if [ -n "$ANALYZE_COMMAND" ]; then
  # Use custom analyze command (eval to handle complex commands with pipes/args)
  ANALYSIS_JSON=$(eval "$ANALYZE_COMMAND \"$LATEST_REPORT\"" 2>/dev/null)
else
  # Use default analyze script
  ANALYSIS_JSON=$("$SCRIPT_DIR/analyze-report.sh" "$LATEST_REPORT" 2>/dev/null)
fi

[ -n "$ANALYSIS_JSON" ] || error "Failed to analyze report"

# Parse the analysis
PRIORITY_ITEM=$(echo "$ANALYSIS_JSON" | jq -r '.priority_item // empty')
DESCRIPTION=$(echo "$ANALYSIS_JSON" | jq -r '.description // empty')
RATIONALE=$(echo "$ANALYSIS_JSON" | jq -r '.rationale // empty')
BRANCH_NAME=$(echo "$ANALYSIS_JSON" | jq -r '.branch_name // empty')

[ -n "$PRIORITY_ITEM" ] || error "Failed to parse priority item from analysis"

# Ensure branch has correct prefix
if [[ "$BRANCH_NAME" != "$BRANCH_PREFIX"* ]]; then
  BRANCH_NAME="${BRANCH_PREFIX}$(echo "$BRANCH_NAME" | sed "s|^[^/]*/||")"
fi

log "Priority item: $PRIORITY_ITEM"
log "Branch: $BRANCH_NAME"
log "Rationale: $RATIONALE"

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN - Would proceed with:"
  echo "$ANALYSIS_JSON" | jq .
  exit 0
fi

# Step 3: Create feature branch
log "Step 3: Creating feature branch..."
git checkout main
git checkout -b "$BRANCH_NAME" || git checkout "$BRANCH_NAME"

# Step 4: Use agent to create PRD
log "Step 4: Creating PRD with $TOOL..."

PRD_FILENAME="prd-$(echo "$BRANCH_NAME" | sed "s|^${BRANCH_PREFIX}||").md"
mkdir -p "$TASKS_DIR"

PRD_PROMPT="Load the prd skill. Create a PRD for: $PRIORITY_ITEM

Description: $DESCRIPTION

Rationale from report analysis: $RATIONALE

Acceptance criteria from analysis:
$(echo "$ANALYSIS_JSON" | jq -r '.acceptance_criteria[]' | sed 's/^/- /')

IMPORTANT CONSTRAINTS:
- NO database migrations or schema changes
- Keep scope small - this should be completable in 2-4 hours
- Break into 3-5 small tasks maximum
- Each task must be verifiable with quality checks and/or browser testing

Save the PRD to: tasks/$PRD_FILENAME"

if [[ "$TOOL" == "amp" ]]; then
  echo "$PRD_PROMPT" | amp --execute --dangerously-allow-all 2>&1 | tee "$OUTPUT_DIR/auto-compound-prd.log"
else
  echo "$PRD_PROMPT" | claude --dangerously-skip-permissions 2>&1 | tee "$OUTPUT_DIR/auto-compound-prd.log"
fi

# Verify PRD was created
PRD_PATH="$TASKS_DIR/$PRD_FILENAME"
[ -f "$PRD_PATH" ] || error "PRD was not created at $PRD_PATH"
log "PRD created: $PRD_PATH"

# Step 5: Use agent to convert PRD to tasks
log "Step 5: Converting PRD to prd.json with $TOOL..."

TASKS_PROMPT="Load the tasks skill. Convert $PRD_PATH to $OUTPUT_DIR/prd.json

Use branch name: $BRANCH_NAME

Remember: Each task must be small enough to complete in one iteration."

if [[ "$TOOL" == "amp" ]]; then
  echo "$TASKS_PROMPT" | amp --execute --dangerously-allow-all 2>&1 | tee "$OUTPUT_DIR/auto-compound-tasks.log"
else
  echo "$TASKS_PROMPT" | claude --dangerously-skip-permissions 2>&1 | tee "$OUTPUT_DIR/auto-compound-tasks.log"
fi

# Verify prd.json was created
[ -f "$OUTPUT_DIR/prd.json" ] || error "prd.json was not created"
log "Tasks created: $(cat "$OUTPUT_DIR/prd.json" | jq '.tasks | length') tasks"

# Commit the PRD and prd.json
git add "$PRD_PATH" "$OUTPUT_DIR/prd.json"
git commit -m "chore: add PRD and tasks for $PRIORITY_ITEM" || true

# Step 6: Run the loop
log "Step 6: Running execution loop (max $MAX_ITERATIONS iterations)..."
"$SCRIPT_DIR/loop.sh" "$MAX_ITERATIONS" 2>&1 | tee "$OUTPUT_DIR/auto-compound-execution.log"

# Step 7: Create PR
log "Step 7: Creating Pull Request..."

git push -u origin "$BRANCH_NAME"

PR_BODY="## Compound Product: $PRIORITY_ITEM

**Generated from report:** $REPORT_NAME

### Rationale
$RATIONALE

### What was done
\`\`\`
$(cat "$OUTPUT_DIR/progress.txt" | tail -50)
\`\`\`

### Tasks completed
\`\`\`json
$(cat "$OUTPUT_DIR/prd.json" | jq '.tasks[] | {id, title, passes}')
\`\`\`

---
*This PR was automatically generated by Compound Product from report analysis.*"

PR_URL=$(gh pr create \
  --title "Compound: $PRIORITY_ITEM" \
  --body "$PR_BODY" \
  --base main \
  --head "$BRANCH_NAME")

log "✅ Complete! PR created: $PR_URL"
log "Review the PR and merge if the changes look good."
