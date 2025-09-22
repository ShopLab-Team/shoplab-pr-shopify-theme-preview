#!/bin/bash
set -e

# Deployment script for Shopify PR Theme Preview Action
# This script handles both creating new themes and updating existing ones

echo "🚀 Starting Shopify PR Theme deployment..."

# Check required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
  echo "Error: GITHUB_TOKEN is required"
  exit 1
fi

if [ -z "$SHOPIFY_FLAG_STORE" ]; then
  echo "Error: SHOPIFY_FLAG_STORE is required"
  exit 1
fi

if [ -z "$SHOPIFY_CLI_THEME_TOKEN" ]; then
  echo "Error: SHOPIFY_CLI_THEME_TOKEN is required"  
  exit 1
fi

if [ -z "$PR_TITLE" ]; then
  echo "Error: PR_TITLE is required"
  exit 1
fi

# Initialize variables
EXISTING_THEME_ID=""
EXISTING_THEME_NAME=""
EXISTING_COMMENT_ID=""
CREATED_THEME_ID=""
THEME_ERRORS=""
THEME_WARNINGS=""
LAST_DELETE_OUTPUT=""

# Helper function: extract the most recent theme marker from PR comments
extract_latest_theme_marker() {
  local input_json
  input_json=$(cat)

  COMMENTS_JSON="$input_json" node - <<'NODE'
const data = process.env.COMMENTS_JSON || "";
if (!data.trim()) {
  process.exit(0);
}

let comments;
try {
  comments = JSON.parse(data);
} catch (error) {
  process.exit(0);
}

const markers = [];
const markerRegex = /<!-- THEME_NAME:(.+?):ID:(\d+):END -->/g;

for (const comment of comments) {
  if (!comment || typeof comment.body !== "string") {
    continue;
  }

  let match;
  while ((match = markerRegex.exec(comment.body)) !== null) {
    markers.push({
      name: match[1],
      id: match[2],
      timestamp: comment.updated_at || comment.created_at || ""
    });
  }
}

if (!markers.length) {
  process.exit(0);
}

markers.sort((a, b) => {
  if (a.timestamp && b.timestamp) {
    return new Date(a.timestamp) - new Date(b.timestamp);
  }
  if (a.timestamp) {
    return -1;
  }
  if (b.timestamp) {
    return 1;
  }
  return 0;
});

const latest = markers[markers.length - 1];
process.stdout.write(`${latest.name}|${latest.id}`);
NODE
}

# Helper function: delete a theme by ID while capturing CLI output
delete_theme_by_id() {
  local theme_id="$1"
  local output=""
  local status=0

  set +e
  output=$(shopify theme delete -t "${theme_id}" --force 2>&1)
  status=$?
  set -e

  LAST_DELETE_OUTPUT="$output"

  if [ $status -eq 0 ]; then
    return 0
  fi

  if echo "$output" | grep -qi 'No themes' || echo "$output" | grep -qi 'not found'; then
    return 2
  fi

  return 1
}

# Function to make GitHub API calls
github_api() {
  local endpoint=$1
  local method=${2:-GET}
  local data=$3
  
  if [ "$method" = "GET" ]; then
    curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com${endpoint}"
  else
    curl -s -X "$method" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Content-Type: application/json" \
      ${data:+-d "$data"} \
      "https://api.github.com${endpoint}"
  fi
}

# Function to send Slack notification
send_slack_notification() {
  local status=$1
  local message=$2
  local preview_url=$3
  local theme_id=$4
  
  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    return 0
  fi
  
  echo "📨 Sending Slack notification..."
  
  # Determine emoji and color based on status
  local emoji=""
  local color=""
  local action_text=""
  case "$status" in
    "success")
      emoji="✅"
      color="good"
      # Determine if this is creation or update based on message
      if echo "$message" | grep -qi "update"; then
        action_text="Theme Updated"
      else
        action_text="Theme Deployed"
      fi
      ;;
    "warning")
      emoji="⚠️"
      color="warning"
      action_text="Theme Created with Warnings"
      ;;
    "error")
      emoji="❌"
      color="danger"
      action_text="Theme Deployment Failed"
      ;;
    *)
      emoji="ℹ️"
      color="#808080"
      action_text="Theme Status"
      ;;
  esac
  
  # Build the Slack message
  local slack_message=""
  
  if [ "$status" = "success" ]; then
    slack_message=$(cat <<EOF
{
  "text": "${emoji} Shopify ${action_text}",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {
          "title": "Repository",
          "value": "${GITHUB_REPOSITORY}",
          "short": true
        },
        {
          "title": "PR",
          "value": "<${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER}|#${PR_NUMBER}: ${PR_TITLE}>",
          "short": true
        },
        {
          "title": "Theme ID",
          "value": "${theme_id}",
          "short": true
        },
        {
          "title": "Preview URL",
          "value": "<${preview_url}|View Preview>",
          "short": true
        }
      ],
      "footer": "Shopify Theme Preview",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  else
    slack_message=$(cat <<EOF
{
  "text": "${emoji} Shopify Theme Preview Failed",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {
          "title": "Repository",
          "value": "${GITHUB_REPOSITORY}",
          "short": true
        },
        {
          "title": "PR",
          "value": "<${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER}|#${PR_NUMBER}: ${PR_TITLE}>",
          "short": true
        },
        {
          "title": "Error",
          "value": "${message}",
          "short": false
        }
      ],
      "footer": "Shopify Theme Preview",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  fi
  
  # Send to Slack
  curl -X POST -H 'Content-type: application/json' \
    --data "$slack_message" \
    "$SLACK_WEBHOOK_URL" 2>/dev/null || echo "⚠️ Failed to send Slack notification"
}

# Function to post error comment on PR
post_error_comment() {
  local error_message=$1
  local theme_id=$2
  
  echo "💬 Posting error comment to PR..."
  
  local comment_body=""
  
  if [ -n "$theme_id" ]; then
    # Theme was created but with errors
    STORE_URL="${SHOPIFY_FLAG_STORE}"
    STORE_URL="${STORE_URL#https://}"
    STORE_URL="${STORE_URL#http://}"
    STORE_URL="${STORE_URL%/}"
    PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${theme_id}"
    
    comment_body=$(cat <<EOF
## ⚠️ Shopify Theme Preview Created with Errors

The theme was created but encountered some issues:

\`\`\`
${error_message}
\`\`\`

**Preview URL (may have issues):** ${PREVIEW_URL}  
**Theme ID:** \`${theme_id}\`

Please fix the errors and push a new commit to update the theme.

<!-- THEME_NAME:${THEME_NAME}:ID:${theme_id}:END -->
EOF
)
  else
    # Theme creation failed completely
    comment_body=$(cat <<EOF
## ❌ Shopify Theme Preview Failed

Failed to create the preview theme due to the following error:

\`\`\`
${error_message}
\`\`\`

Please fix the errors and push a new commit to retry.
EOF
)
  fi
  
  # Escape the comment body for JSON
  local escaped_body=$(echo "$comment_body" | jq -Rs .)
  
  # Post comment
  local response=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" "POST" "{\"body\":${escaped_body}}")
  
  if echo "$response" | grep -q '"id"'; then
    echo "✅ Error comment posted successfully"
  else
    echo "⚠️ Warning: Could not post error comment"
  fi
}

# Function to find and delete the oldest theme from open PRs
handle_theme_limit() {
  echo "⚠️ Theme limit reached, searching for oldest theme to remove..."

  local open_prs
  open_prs=$(github_api "/repos/${GITHUB_REPOSITORY}/pulls?state=open&sort=updated&direction=asc&per_page=100")

  local theme_list
  local theme_count="unknown"

  if theme_list=$(shopify theme list --json 2>/dev/null); then
    theme_count=$(printf '%s' "$theme_list" | jq 'length' 2>/dev/null || echo "unknown")
    echo "  Store currently reports ${theme_count} theme(s)"
  else
    echo "  ⚠️ Unable to retrieve theme list"
  fi

  local found_candidate=false

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue

    local pr_number pr_updated
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number // empty')
    pr_updated=$(printf '%s' "$pr_json" | jq -r '.updated_at // ""')

    if [ -z "$pr_number" ]; then
      continue
    fi

    if [ "$pr_number" = "$PR_NUMBER" ]; then
      continue
    fi

    if printf '%s' "$pr_json" | jq -e '(.labels // []) | map(.name) | any(. == "preserve-theme")' >/dev/null 2>&1; then
      echo "  Skipping PR #${pr_number} (has preserve-theme label)"
      continue
    fi

    local pr_comments
    pr_comments=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments")

    local marker theme_id theme_name
    marker=$(printf '%s' "$pr_comments" | extract_latest_theme_marker)
    if [ -n "$marker" ]; then
      theme_name=${marker%|*}
      theme_id=${marker##*|}
    else
      echo "  No theme marker found for PR #${pr_number}"
      continue
    fi

    found_candidate=true
    echo "  Evaluating theme ${theme_id} from PR #${pr_number} (updated: ${pr_updated})"

    if delete_theme_by_id "$theme_id"; then
      echo "🗑️ Deleted theme ${theme_id} from PR #${pr_number}"

      local comment_body
      comment_body=$(cat <<EOF
## ⚠️ Theme Auto-Removed Due to Store Limit

Your preview theme was automatically deleted to make room for newer PRs (Shopify limit: 20 themes).

**To recreate your preview theme:**
- Add the label \`rebuild-theme\` to this PR
- Or push a new commit

The theme will be automatically recreated.
EOF
)

      local escaped_body
      escaped_body=$(echo "$comment_body" | jq -Rs .)
      github_api "/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" "POST" "{\"body\":${escaped_body}}" >/dev/null

      echo "✅ Oldest theme deleted from PR #${pr_number}"
      return 0
    else
      local delete_status=$?
      if [ $delete_status -eq 2 ]; then
        echo "  Theme ${theme_id} referenced by PR #${pr_number} no longer exists on the store"
      else
        echo "  Failed to delete theme ${theme_id} from PR #${pr_number}"
        echo "$LAST_DELETE_OUTPUT"
      fi
      # Try next candidate
    fi
  done < <(printf '%s' "$open_prs" | jq -c '.[]?')

  if [ "$found_candidate" = false ]; then
    echo "⚠️ No deletable themes found (all may have preserve-theme label or no markers)"
  else
    echo "⚠️ No deletable themes could be removed successfully"
  fi

  return 1
}

# Function to retry theme upload to existing theme
retry_theme_upload() {
  local theme_id="$1"
  local max_retries=3
  local retry_count=0
  
  echo "🔄 Retrying upload to theme ID: ${theme_id}"
  
  while [ $retry_count -lt $max_retries ]; do
    echo "📤 Upload attempt $((retry_count + 1)) of ${max_retries}..."
    
    # Try to push to the existing theme
    OUTPUT=$(shopify theme push \
      --theme "${theme_id}" \
      --nodelete \
      --no-color \
      --json 2>&1)
    
    # Check if upload was successful
    if echo "$OUTPUT" | grep -q '"errors":\s*{}' || ! echo "$OUTPUT" | grep -q '"errors"'; then
      echo "✅ Theme updated successfully"
      return 0
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      echo "⚠️ Upload failed, retrying in 3 seconds..."
      sleep 3
    fi
  done
  
  echo "❌ Failed to upload to theme after ${max_retries} attempts"
  echo "Last output: $OUTPUT"
  return 1
}

# Function to create theme with retry on limit
create_theme_with_retry() {
  local theme_name="$1"
  local max_retries=3
  local retry_count=0
  local theme_created=false
  
  while [ $retry_count -lt $max_retries ]; do
    if [ "$theme_created" = false ]; then
      echo "🎨 Creating new theme: ${theme_name} (attempt $((retry_count + 1)))"
      
      # Create new theme - capture output
      OUTPUT=$(shopify theme push \
        --unpublished \
        --theme "${theme_name}" \
        --nodelete \
        --no-color \
        --json 2>&1)
      
      # Check if we hit the theme limit
      if echo "$OUTPUT" | grep -qi "limit\|maximum\|exceeded\|too many"; then
        echo "⚠️ Theme limit error detected"
        
        if [ $retry_count -eq 0 ]; then
          # First attempt - try to clean up old themes
          if handle_theme_limit; then
            echo "🔄 Retrying theme creation after cleanup..."
            retry_count=$((retry_count + 1))
            sleep 2
            continue
          else
            echo "❌ Could not free up theme slots"
            return 1
          fi
        fi
      fi
      
      # Try to extract theme ID (theme might be created even with errors)
      THEME_ID=$(echo "$OUTPUT" | node -e '
        let data = "";
        process.stdin.on("data", chunk => data += chunk);
        process.stdin.on("end", () => {
          try {
            const json = JSON.parse(data);
            const themeId = json.theme?.id || "";
            process.stdout.write(String(themeId));
          } catch (e) {
            // If JSON parsing fails, try to extract from regular output
            const match = data.match(/Theme ID: (\d+)/);
            if (match) {
              process.stdout.write(match[1]);
            }
          }
        });
      ' 2>/dev/null || echo "")
      
      if [ -n "${THEME_ID}" ] && [ "${THEME_ID}" != "null" ]; then
        theme_created=true
        CREATED_THEME_ID="${THEME_ID}"
        echo "✅ Theme created with ID: ${THEME_ID}"
        
        # Check for errors or warnings in the output
        if echo "$OUTPUT" | grep -q '"errors"' || echo "$OUTPUT" | grep -q '"warning"'; then
          # Extract errors/warnings
          THEME_ERRORS=$(echo "$OUTPUT" | node -e '
            let data = "";
            process.stdin.on("data", chunk => data += chunk);
            process.stdin.on("end", () => {
              try {
                const json = JSON.parse(data);
                if (json.theme?.errors) {
                  const errors = Object.entries(json.theme.errors)
                    .map(([file, msgs]) => `${file}: ${msgs.join(", ")}`)
                    .join("\n");
                  process.stdout.write(errors);
                } else if (json.theme?.warning) {
                  process.stdout.write(json.theme.warning);
                }
              } catch (e) {
                // Fallback to raw output
                process.stdout.write(data);
              }
            });
          ' 2>/dev/null || echo "$OUTPUT")
          
          echo "⚠️ Theme created with errors/warnings:"
          echo "$THEME_ERRORS"
          
          # Don't retry if theme was created, even with errors
          export THEME_ID
          export THEME_ERRORS
          return 0
        else
          # Theme created successfully without errors
          export THEME_ID
          return 0
        fi
      fi
    else
      # Theme already created, just retry the upload
      if retry_theme_upload "${CREATED_THEME_ID}"; then
        THEME_ID="${CREATED_THEME_ID}"
        export THEME_ID
        return 0
      fi
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      echo "⚠️ Operation failed, retrying in 3 seconds..."
      sleep 3
    fi
  done
  
  echo "❌ Failed to create/upload theme after ${max_retries} attempts"
  echo "Last output: $OUTPUT"
  
  # Post error comment and send Slack notification if theme creation failed completely
  if [ "$theme_created" = false ]; then
    post_error_comment "${OUTPUT}" ""
    send_slack_notification "error" "Failed to create theme: ${OUTPUT}" "" ""
  else
    # Theme was created but uploads failed
    post_error_comment "${THEME_ERRORS}" "${CREATED_THEME_ID}"
    STORE_URL="${SHOPIFY_FLAG_STORE}"
    STORE_URL="${STORE_URL#https://}"
    STORE_URL="${STORE_URL#http://}"
    STORE_URL="${STORE_URL%/}"
    PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${CREATED_THEME_ID}"
    send_slack_notification "warning" "Theme created with errors: ${THEME_ERRORS}" "${PREVIEW_URL}" "${CREATED_THEME_ID}"

    if [ -n "${CREATED_THEME_ID}" ]; then
      echo "🧹 Cleaning up failed theme ${CREATED_THEME_ID}"
      if delete_theme_by_id "${CREATED_THEME_ID}"; then
        echo "✅ Failed theme ${CREATED_THEME_ID} removed"
      else
        delete_status=$?
        if [ $delete_status -ne 2 ]; then
          echo "$LAST_DELETE_OUTPUT"
        fi
        echo "⚠️ Could not remove failed theme ${CREATED_THEME_ID}"
      fi
    fi
  fi
  
  return 1
}

# Check if PR has no-sync label
HAS_NO_SYNC_LABEL="false"
if [ -n "$PR_LABELS" ]; then
  # Parse the JSON array of labels
  if echo "$PR_LABELS" | grep -q '"no-sync"'; then
    HAS_NO_SYNC_LABEL="true"
    echo "🔒 Found 'no-sync' label - will skip pulling theme settings"
  fi
fi

# Sanitize PR title for theme name
THEME_NAME=$(printf '%s' "$PR_TITLE" | \
  tr -cd '[:alnum:][:space:]-_.[]' | \
  sed -E 's/[[:space:]]+/ /g' | \
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
  cut -c1-50)

echo "📝 Theme name: ${THEME_NAME}"

# Find existing theme information from PR comments
echo "🔍 Checking for existing theme..."
COMMENTS=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments")

THEME_MARKER=$(printf '%s' "$COMMENTS" | extract_latest_theme_marker)

if [ -n "$THEME_MARKER" ]; then
  EXISTING_THEME_NAME=${THEME_MARKER%|*}
  EXISTING_THEME_ID=${THEME_MARKER##*|}
fi

if [ -n "$EXISTING_THEME_ID" ]; then
  echo "✅ Found existing theme ID: ${EXISTING_THEME_ID}"
  if [ -n "$EXISTING_THEME_NAME" ] && [ "$EXISTING_THEME_NAME" != "$THEME_NAME" ]; then
    echo "ℹ️ Existing theme name on store: ${EXISTING_THEME_NAME}"
  fi
else
  echo "📝 No existing theme found, will create new one"
fi


# Run build command if provided
if [ -n "${BUILD_COMMAND}" ]; then
  echo "🔨 Running build command: ${BUILD_COMMAND}"
  eval "${BUILD_COMMAND}"
  echo "✅ Build completed"
fi

# Deploy or update theme
if [ -n "${EXISTING_THEME_ID}" ]; then
  echo "🔄 Updating existing theme ID: ${EXISTING_THEME_ID}"
  echo "💾 Preserving theme settings (excluding JSON files from update)"
  
  # Always exclude JSON files when updating existing themes to preserve settings
  # The no-sync label only affects initial theme creation, not updates
  # Note: We allow locale default files (like en.default.json) to be updated
  UPDATE_OUTPUT=$(shopify theme push \
    --theme "${EXISTING_THEME_ID}" \
    --nodelete \
    --no-color \
    --ignore "templates/*.json" \
    --ignore "sections/*.json" \
    --ignore "config/settings_data.json" \
    --ignore "snippets/*.json" \
    --json 2>&1)
  
  UPDATE_SUCCESS=$?
  
  # Check for errors in update
  if [ $UPDATE_SUCCESS -ne 0 ] || echo "$UPDATE_OUTPUT" | grep -q '"errors"'; then
    echo "⚠️ Theme update encountered errors"
    THEME_ERRORS=$(echo "$UPDATE_OUTPUT" | node -e '
      let data = "";
      process.stdin.on("data", chunk => data += chunk);
      process.stdin.on("end", () => {
        try {
          const json = JSON.parse(data);
          if (json.theme?.errors) {
            const errors = Object.entries(json.theme.errors)
              .map(([file, msgs]) => `${file}: ${msgs.join(", ")}`)
              .join("\n");
            process.stdout.write(errors);
          } else {
            process.stdout.write(data);
          }
        } catch (e) {
          process.stdout.write(data);
        }
      });
    ' 2>/dev/null || echo "$UPDATE_OUTPUT")
    
    post_error_comment "${THEME_ERRORS}" "${EXISTING_THEME_ID}"
    
    STORE_URL="${SHOPIFY_FLAG_STORE}"
    STORE_URL="${STORE_URL#https://}"
    STORE_URL="${STORE_URL#http://}"
    STORE_URL="${STORE_URL%/}"
    PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${EXISTING_THEME_ID}"
    
    send_slack_notification "warning" "Theme update failed: ${THEME_ERRORS}" "${PREVIEW_URL}" "${EXISTING_THEME_ID}"
    exit 1
  fi
  
  THEME_ID="${EXISTING_THEME_ID}"
  echo "✅ Theme updated successfully"
  
else
  # Pull settings from source theme (only on initial creation and if no-sync label is not present)
  if [ "$HAS_NO_SYNC_LABEL" = "true" ]; then
    echo "⏭️ Skipping theme settings pull due to 'no-sync' label"
    echo "📄 Using JSON files from repository as-is"
  else
    if [ -n "${SOURCE_THEME_ID}" ]; then
      echo "📥 Pulling settings from theme ID: ${SOURCE_THEME_ID}"
      THEME_SELECTOR="--theme ${SOURCE_THEME_ID}"
    else
      echo "📥 No source theme specified, pulling from live theme"
      THEME_SELECTOR="--live"
    fi
    
    echo "⬇️ Pulling JSON configuration files..."
    shopify theme pull \
      ${THEME_SELECTOR} \
      --only "templates/*.json" \
      --only "sections/*.json" \
      --only "config/settings_data.json" \
      --only "locales/*.json" \
      --only "snippets/*.json" \
      --nodelete \
      --no-color 2>&1 | while IFS= read -r line; do
        # Filter out noisy output
        if [[ ! "$line" =~ "Pulling theme files from" ]] && \
           [[ ! "$line" =~ "Theme pulled successfully" ]]; then
          echo "$line"
        fi
      done || echo "⚠️ Warning: Could not pull all settings files (this is okay if some don't exist)"
  fi
  
  # Use the retry function to create theme
  if create_theme_with_retry "${THEME_NAME}"; then
    # THEME_ID is set by the function
    echo "🎆 Theme creation successful!"
    
    # Generate preview URL
    STORE_URL="${SHOPIFY_FLAG_STORE}"
    STORE_URL="${STORE_URL#https://}"
    STORE_URL="${STORE_URL#http://}"
    STORE_URL="${STORE_URL%/}"
    PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${THEME_ID}"
    
    echo "🔗 Preview URL: ${PREVIEW_URL}"
    
    # Create the comment body
    if [ -n "$THEME_ERRORS" ]; then
      # Theme created with warnings/errors
      COMMENT_BODY=$(cat <<EOF
## ⚠️ Shopify Theme Preview Created with Warnings

**Preview your changes:** ${PREVIEW_URL}

**Theme:** ${THEME_NAME}  
**Theme ID:** \`${THEME_ID}\`

The theme was created but encountered some issues:
\`\`\`
${THEME_ERRORS}
\`\`\`

This preview theme will be automatically deleted when the PR is closed or merged.

<!-- THEME_NAME:${THEME_NAME}:ID:${THEME_ID}:END -->
EOF
)
      send_slack_notification "warning" "Theme created with warnings" "${PREVIEW_URL}" "${THEME_ID}"
    else
      # Theme created successfully
      COMMENT_BODY=$(cat <<EOF
## 🚀 Shopify Theme Preview

**Preview your changes:** ${PREVIEW_URL}

**Theme:** ${THEME_NAME}  
**Theme ID:** \`${THEME_ID}\`

This preview theme will be automatically deleted when the PR is closed or merged.

<!-- THEME_NAME:${THEME_NAME}:ID:${THEME_ID}:END -->
EOF
)
      send_slack_notification "success" "Theme deployed successfully" "${PREVIEW_URL}" "${THEME_ID}"
    fi
    
    # Escape the comment body for JSON
    ESCAPED_BODY=$(echo "$COMMENT_BODY" | jq -Rs .)
    
    # Post comment with preview URL
    echo "💬 Posting preview comment..."
    RESPONSE=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" "POST" "{\"body\":${ESCAPED_BODY}}")
    
    if echo "$RESPONSE" | grep -q '"id"'; then
      echo "✅ Preview comment posted successfully"
    else
      echo "⚠️ Warning: Could not post comment, but theme was created successfully"
      echo "Response: $RESPONSE"
    fi
  else
    echo "❌ Failed to create theme"
    exit 1
  fi
fi

# Output theme ID for other steps
echo "theme-id=${THEME_ID}" >> $GITHUB_OUTPUT

echo "🎉 Deployment complete!"
