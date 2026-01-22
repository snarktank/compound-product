#!/bin/bash
# Analyze a report and pick #1 actionable priority
# Supports multiple LLM providers: Anthropic, OpenRouter, AI Gateway
#
# Usage: ./analyze-report.sh <report-path>
# Output: JSON to stdout
#
# Environment variables (uses first one found):
#   ANTHROPIC_API_KEY     - Anthropic API directly
#   OPENROUTER_API_KEY    - OpenRouter (uses claude-sonnet-4-20250514)
#   AI_GATEWAY_URL        - Any OpenAI-compatible endpoint (requires AI_GATEWAY_API_KEY)

set -e

REPORT_PATH="$1"

if [ -z "$REPORT_PATH" ]; then
  echo "Usage: ./analyze-report.sh <report-path>" >&2
  exit 1
fi

if [ ! -f "$REPORT_PATH" ]; then
  echo "Error: Report file not found: $REPORT_PATH" >&2
  exit 1
fi

# Detect which provider is available
PROVIDER=""
if [ -n "$ANTHROPIC_API_KEY" ]; then
  PROVIDER="anthropic"
elif [ -n "$OPENROUTER_API_KEY" ]; then
  PROVIDER="openrouter"
elif [ -n "$AI_GATEWAY_API_KEY" ]; then
  PROVIDER="gateway"
  # Default to Vercel AI Gateway URL if not specified
  AI_GATEWAY_URL="${AI_GATEWAY_URL:-https://ai-gateway.vercel.sh/v1}"
fi

if [ -z "$PROVIDER" ]; then
  echo "" >&2
  echo "╔══════════════════════════════════════════════════════════════════╗" >&2
  echo "║  No LLM provider configured. Set one of these environment vars: ║" >&2
  echo "╠══════════════════════════════════════════════════════════════════╣" >&2
  echo "║                                                                  ║" >&2
  echo "║  Option 1: Vercel AI Gateway (recommended)                       ║" >&2
  echo "║    export AI_GATEWAY_API_KEY=your-key                            ║" >&2
  echo "║                                                                  ║" >&2
  echo "║  Option 2: Anthropic API (direct)                                ║" >&2
  echo "║    export ANTHROPIC_API_KEY=sk-ant-...                           ║" >&2
  echo "║                                                                  ║" >&2
  echo "║  Option 3: OpenRouter                                            ║" >&2
  echo "║    export OPENROUTER_API_KEY=sk-or-...                           ║" >&2
  echo "║                                                                  ║" >&2
  echo "╚══════════════════════════════════════════════════════════════════╝" >&2
  echo "" >&2
  exit 1
fi

REPORT_CONTENT=$(cat "$REPORT_PATH")

PROMPT="You are analyzing a daily report for a software product.

Read this report and identify the #1 most actionable item that should be worked on TODAY.

CONSTRAINTS:
- Must NOT require database migrations (no schema changes)
- Must be completable in a few hours of focused work
- Must be a clear, specific task (not vague like 'improve conversion')
- Prefer fixes over new features
- Prefer high-impact, low-effort items
- Focus on UI/UX improvements, copy changes, bug fixes, or configuration changes

REPORT:
$REPORT_CONTENT

Respond with ONLY a JSON object (no markdown, no code fences, no explanation):
{
  \"priority_item\": \"Brief title of the item\",
  \"description\": \"2-3 sentence description of what needs to be done\",
  \"rationale\": \"Why this is the #1 priority based on the report\",
  \"acceptance_criteria\": [\"List of 3-5 specific, verifiable criteria\"],
  \"estimated_tasks\": 3,
  \"branch_name\": \"compound/kebab-case-feature-name\"
}"

PROMPT_ESCAPED=$(echo "$PROMPT" | jq -Rs .)

# Make the API call based on provider
case "$PROVIDER" in
  anthropic)
    RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
      -H "Content-Type: application/json" \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -d "{
        \"model\": \"claude-sonnet-4-20250514\",
        \"max_tokens\": 1024,
        \"messages\": [{\"role\": \"user\", \"content\": $PROMPT_ESCAPED}]
      }")
    TEXT=$(echo "$RESPONSE" | jq -r '.content[0].text // empty')
    ;;
    
  openrouter)
    RESPONSE=$(curl -s https://openrouter.ai/api/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENROUTER_API_KEY" \
      -d "{
        \"model\": \"anthropic/claude-sonnet-4-20250514\",
        \"max_tokens\": 1024,
        \"messages\": [{\"role\": \"user\", \"content\": $PROMPT_ESCAPED}]
      }")
    TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    ;;
    
  gateway)
    MODEL="${AI_GATEWAY_MODEL:-anthropic/claude-sonnet-4-20250514}"
    RESPONSE=$(curl -s "${AI_GATEWAY_URL}/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AI_GATEWAY_API_KEY" \
      -d "{
        \"model\": \"$MODEL\",
        \"max_tokens\": 1024,
        \"messages\": [{\"role\": \"user\", \"content\": $PROMPT_ESCAPED}]
      }")
    TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
    ;;
esac

if [ -z "$TEXT" ]; then
  echo "Error: Failed to get response from $PROVIDER" >&2
  echo "Response: $RESPONSE" >&2
  exit 1
fi

# Try to parse as JSON, handle potential markdown wrapping
if echo "$TEXT" | jq . >/dev/null 2>&1; then
  echo "$TEXT" | jq .
else
  # Try to extract JSON from markdown code block
  JSON_EXTRACTED=$(echo "$TEXT" | sed -n '/^{/,/^}/p' | head -20)
  if echo "$JSON_EXTRACTED" | jq . >/dev/null 2>&1; then
    echo "$JSON_EXTRACTED" | jq .
  else
    echo "Error: Could not parse response as JSON" >&2
    echo "Response text: $TEXT" >&2
    exit 1
  fi
fi
