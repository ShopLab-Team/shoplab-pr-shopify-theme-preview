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
  
  # Escape single quotes and backslashes for JSON
  local escaped_message
  escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
  
  # Determine emoji and color based on status
  local emoji
  local color
  local status_text
  case "$status" in
    success)
      emoji="✅"
      color="#36a64f"
      status_text="Theme deployed successfully"
      ;;
    error)
      emoji="❌"
      color="#ff0000"
      status_text="Theme deployment failed"
      ;;
    warning)
      emoji="⚠️"
      color="#ff9900"
      status_text="Theme deployed with warnings"
      ;;
    *)
      emoji="ℹ️"
      color="#0099ff"
      status_text="Theme deployment info"
      ;;
  esac
  
  # Build PR URL
  local pr_url=""
  if [ -n "$GITHUB_SERVER_URL" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$PR_NUMBER" ]; then
    pr_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER}"
  fi
  
  # Prepare PR title with proper escaping
  local escaped_pr_title
  escaped_pr_title=$(printf '%s' "$PR_TITLE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
  
  # Build attachment fields
  local attachment_fields="["
  
  # Add Repository field
  if [ -n "$GITHUB_REPOSITORY" ]; then
    attachment_fields="${attachment_fields}{\"title\":\"Repository\",\"value\":\"${GITHUB_REPOSITORY}\",\"short\":true},"
  fi
  
  # Add PR field with link
  if [ -n "$pr_url" ] && [ -n "$PR_NUMBER" ]; then
    attachment_fields="${attachment_fields}{\"title\":\"PR\",\"value\":\"<${pr_url}|#${PR_NUMBER}: ${escaped_pr_title}>\",\"short\":true},"
  fi
  
  # Add Theme ID field
  if [ -n "$theme_id" ]; then
    attachment_fields="${attachment_fields}{\"title\":\"Theme ID\",\"value\":\"${theme_id}\",\"short\":true},"
  fi
  
  # Add Preview URL field
  if [ -n "$preview_url" ]; then
    attachment_fields="${attachment_fields}{\"title\":\"Preview URL\",\"value\":\"<${preview_url}|View Preview>\",\"short\":true},"
  fi
  
  # Add Status field
  attachment_fields="${attachment_fields}{\"title\":\"Status\",\"value\":\"${status_text}\",\"short\":false}"
  
  # Add message as additional field if it's not the default status text
  if [ -n "$escaped_message" ] && [ "$escaped_message" != "$status_text" ]; then
    attachment_fields="${attachment_fields},{\"title\":\"Details\",\"value\":\"${escaped_message}\",\"short\":false}"
  fi
  
  attachment_fields="${attachment_fields}]"
  
  # Create rich Slack payload with attachments
  local payload
  payload=$(cat <<EOF
{
  "username": "PR Theme Preview Bot",
  "icon_emoji": ":shopify:",
  "text": "${emoji} Shopify Theme Deployed",
  "attachments": [
    {
      "color": "$color",
      "fields": $attachment_fields,
      "footer": "Shopify Theme Preview",
      "ts": $(date +%s)
    }
  ]
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
