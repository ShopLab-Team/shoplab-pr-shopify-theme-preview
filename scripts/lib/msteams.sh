#!/bin/bash
# Microsoft Teams notification functions for Shopify theme deployment scripts

# Source common utilities if not already loaded
[[ -z "${COMMON_UTILS_LOADED}" ]] && source "${BASH_SOURCE%/*}/common.sh" && COMMON_UTILS_LOADED=1

# Function to send MS Teams notification
send_msteams_notification() {
  if [ -z "$MS_TEAMS_WEBHOOK_URL" ]; then
    echo "⚠️ MS Teams webhook URL not configured, skipping notification" >&2
    return 0
  fi
  
  local status="${1:-info}"  # success, error, warning, info
  local message="${2:-No message provided}"
  local preview_url="${3:-}"
  local theme_id="${4:-}"
  
  # Escape for JSON
  local escaped_message
  escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/$/\\n/g' | tr -d '\n')
  
  # Determine color and title based on status
  local theme_color
  local status_text
  local activity_image
  case "$status" in
    success)
      theme_color="28a745"
      status_text="Theme deployed successfully"
      activity_image="https://img.icons8.com/color/48/000000/checkmark.png"
      ;;
    error)
      theme_color="dc3545"
      status_text="Theme deployment failed"
      activity_image="https://img.icons8.com/color/48/000000/cancel.png"
      ;;
    warning)
      theme_color="ffc107"
      status_text="Theme deployed with warnings"
      activity_image="https://img.icons8.com/color/48/000000/warning-shield.png"
      ;;
    *)
      theme_color="0078d4"
      status_text="Theme deployment info"
      activity_image="https://img.icons8.com/color/48/000000/info.png"
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
  
  # Build facts (similar to Slack fields)
  local facts="["
  
  # Add Repository fact
  if [ -n "$GITHUB_REPOSITORY" ]; then
    facts="${facts}{\"name\":\"Repository\",\"value\":\"${GITHUB_REPOSITORY}\"},"
  fi
  
  # Add PR fact
  if [ -n "$PR_NUMBER" ]; then
    if [ -n "$pr_url" ]; then
      facts="${facts}{\"name\":\"Pull Request\",\"value\":\"[#${PR_NUMBER}: ${escaped_pr_title}](${pr_url})\"},"
    else
      facts="${facts}{\"name\":\"Pull Request\",\"value\":\"#${PR_NUMBER}: ${escaped_pr_title}\"},"
    fi
  fi
  
  # Add Theme ID fact
  if [ -n "$theme_id" ]; then
    facts="${facts}{\"name\":\"Theme ID\",\"value\":\"${theme_id}\"},"
  fi
  
  # Add Status fact
  facts="${facts}{\"name\":\"Status\",\"value\":\"${status_text}\"}"
  
  facts="${facts}]"
  
  # Build potential actions
  local potential_actions="["
  
  # Add Preview URL action
  if [ -n "$preview_url" ]; then
    potential_actions="${potential_actions}{\"@type\":\"OpenUri\",\"name\":\"View Preview\",\"targets\":[{\"os\":\"default\",\"uri\":\"${preview_url}\"}]},"
  fi
  
  # Add PR URL action
  if [ -n "$pr_url" ]; then
    potential_actions="${potential_actions}{\"@type\":\"OpenUri\",\"name\":\"View Pull Request\",\"targets\":[{\"os\":\"default\",\"uri\":\"${pr_url}\"}]}"
  else
    # Remove trailing comma if no PR URL
    potential_actions="${potential_actions%,}"
  fi
  
  potential_actions="${potential_actions}]"
  
  # Build sections with details if message is not the status text
  local sections="["
  sections="${sections}{\"activityTitle\":\"Shopify Theme Deployed\",\"activitySubtitle\":\"${status_text}\",\"activityImage\":\"${activity_image}\",\"facts\":${facts},\"markdown\":true}"
  
  # Add details section if message differs from status text
  if [ -n "$escaped_message" ] && [ "$escaped_message" != "${status_text}\\n" ]; then
    sections="${sections},{\"text\":\"**Details:**\\n\\n${escaped_message}\",\"markdown\":true}"
  fi
  
  sections="${sections}]"
  
  # Create MS Teams MessageCard payload (Connector Card format)
  local payload
  payload=$(cat <<EOF
{
  "@type": "MessageCard",
  "@context": "https://schema.org/extensions",
  "summary": "Shopify Theme Deployed",
  "themeColor": "${theme_color}",
  "title": "Shopify Theme Preview",
  "sections": ${sections},
  "potentialAction": ${potential_actions}
}
EOF
)

  # Send with timeout to prevent hanging
  local response
  response=$(curl -s -X POST -H 'Content-Type: application/json' \
    --connect-timeout 5 --max-time 10 \
    --data "$payload" \
    "$MS_TEAMS_WEBHOOK_URL" 2>&1)
  
  # Check if the request was successful (MS Teams returns "1" on success)
  if [ $? -eq 0 ]; then
    echo "✅ MS Teams notification sent" >&2
  else
    echo "⚠️ Failed to send MS Teams notification: $response" >&2
  fi
}

# Export functions for use in other scripts
export -f send_msteams_notification

