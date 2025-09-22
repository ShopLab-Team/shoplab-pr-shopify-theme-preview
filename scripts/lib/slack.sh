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
  
  # Create Slack payload using Node.js for proper JSON encoding
  local payload
  payload=$(node -e "
    const emoji = '$emoji'.replace(/\\\\'/g, \"'\");
    const action_text = process.env.GITHUB_EVENT_NAME === 'pull_request' ? 'PR' : 'Action';
    const repo = '$GITHUB_REPOSITORY'.replace(/\\\\'/g, \"'\");
    const pr_value = process.env.PR_NUMBER || 'N/A';
    const status_title = '$status'.replace(/\\\\'/g, \"'\") === 'success' ? 'Status' : 'Error';
    const message = '$escaped_message'.replace(/\\\\'/g, \"'\");
    const color = '$color';
    const theme_id = '$theme_id'.replace(/\\\\'/g, \"'\");
    const preview = '$preview_url'.replace(/\\\\'/g, \"'\");
    const ts = Math.floor(Date.now() / 1000);
    
    const footer = process.env.GITHUB_SERVER_URL + '/' + repo + '/actions/runs/' + process.env.GITHUB_RUN_ID;
    
    const payload = {
      username: 'Shopify Theme Bot',
      icon_emoji: ':shopify:',
      attachments: [
        {
          color: color,
          fallback: emoji + ' Theme deployment ' + status + ' for ' + action_text + ' #' + pr_value,
          pretext: emoji + ' *Shopify Theme Deployment*',
          fields: [
            {title: 'Repository', value: '<' + process.env.GITHUB_SERVER_URL + '/' + repo + '|' + repo + '>', short: true},
            {title: action_text + ' Number', value: '<' + process.env.GITHUB_SERVER_URL + '/' + repo + '/pull/' + pr_value + '|#' + pr_value + '>', short: true}
          ],
          footer: footer,
          ts: ts
        }
      ]
    };
    
    if (theme_id) {
      payload.attachments[0].fields.push({title: 'Theme ID', value: theme_id, short: true});
    }
    if (preview) {
      payload.attachments[0].fields.push({title: 'Preview URL', value: '<' + preview + '|View Preview>', short: true});
    }
    if (message) {
      payload.attachments[0].fields.push({title: status_title, value: message, short: false});
    }
    
    console.log(JSON.stringify(payload));
 ")

  # Send with timeout to prevent hanging
  curl -s -X POST -H 'Content-type: application/json' \
    --connect-timeout 5 --max-time 10 \
    --data "$payload" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || echo "⚠️ Failed to send Slack notification" >&2
}

# Export functions for use in other scripts
export -f send_slack_notification
