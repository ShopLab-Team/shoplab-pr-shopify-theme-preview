#!/bin/bash
# Slack notification functions for Shopify theme deployment scripts

# Source common utilities if not already loaded
[[ -z "${COMMON_UTILS_LOADED}" ]] && source "${BASH_SOURCE%/*}/common.sh" && COMMON_UTILS_LOADED=1

# Function to send Slack notification
send_slack_notification() {
  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    echo "⚠️ Slack webhook URL not configured, skipping notification" >&2
    return 0
  fi
  
  local status="${1:-info}"  # success, error, warning, info
  local message="${2:-No message provided}"
  local preview_url="${3:-}"
  local theme_id="${4:-}"
  
  # Escape single quotes for shell
  local escaped_message
  escaped_message=$(printf '%s' "$message" | sed "s/'/\\\\'/g")
  
  # Determine emoji and color based on status
  local emoji
  local color
  case "$status" in
    success)
      emoji="✅"
      color="#36a64f"
      ;;
    error)
      emoji="❌"
      color="#ff0000"
      ;;
    warning)
      emoji="⚠️"
      color="#ff9900"
      ;;
    *)
      emoji="ℹ️"
      color="#0099ff"
      ;;
  esac
  
  # Build simple Slack message
  local fields=""
  
  # Add theme ID field if provided
  if [ -n "$theme_id" ]; then
    fields="${fields}*Theme ID:* \`${theme_id}\`\\n"
  fi
  
  # Add preview URL if provided
  if [ -n "$preview_url" ]; then
    fields="${fields}*Preview:* <${preview_url}|View Preview>\\n"
  fi
  
  # Add message if provided
  if [ -n "$escaped_message" ]; then
    fields="${fields}\\n${escaped_message}"
  fi
  
  # Create simple JSON payload
  local text="${emoji} Shopify Theme ${status} for PR #${PR_NUMBER}\\n${fields}"
  
  local payload
  payload=$(cat <<EOF
{
  "text": "$text",
  "username": "Shopify Theme Bot",
  "icon_emoji": ":shopify:"
}
EOF
)

  # Send with timeout to prevent hanging
  curl -s -X POST -H 'Content-type: application/json' \
    --connect-timeout 5 --max-time 10 \
    --data "$payload" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || echo "⚠️ Failed to send Slack notification" >&2
}

# Export functions for use in other scripts
export -f send_slack_notification
