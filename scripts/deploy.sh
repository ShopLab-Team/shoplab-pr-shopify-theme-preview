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
LAST_UPLOAD_OUTPUT=""

truncate_for_slack() {
  local input="$1"
  local max_length="${2:-400}"
  local truncated="$input"
  if [ "${#input}" -gt "$max_length" ]; then
    truncated="${input:0:max_length}…"
  fi
  printf '%s' "$truncated"
}

extract_theme_cli_json() {
  node - <<'NODE'
const fs = require('fs');
const data = fs.readFileSync(0, 'utf8');
if (!data.trim()) {
  process.exit(1);
}

const lines = data.split(/\r?\n/);
let buffer = '';
for (let i = lines.length - 1; i >= 0; i -= 1) {
  const line = lines[i];
  buffer = buffer ? `${line}\n${buffer}` : line;
  const trimmed = buffer.trim();
  if (!trimmed.startsWith('{')) {
    continue;
  }
  try {
    const parsed = JSON.parse(trimmed);
    process.stdout.write(JSON.stringify(parsed));
    process.exit(0);
  } catch (error) {
    continue;
  }
}
process.exit(1);
NODE
}

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

cleanup_failed_theme() {
  local theme_id="$1"
  if [ -z "$theme_id" ]; then
    return 0
  fi

  echo "🧹 Cleaning up failed theme ${theme_id}"
  if delete_theme_by_id "$theme_id"; then
    echo "✅ Failed theme ${theme_id} removed"
    return 0
  fi

  local delete_status=$?
  if [ $delete_status -ne 2 ]; then
    echo "$LAST_DELETE_OUTPUT"
  fi
  echo "⚠️ Could not remove failed theme ${theme_id}"
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

  # Determine emoji, color, and contextual text based on status
  local emoji=""
  local color=""
  local action_text=""
  local status_field_title="Status"

  case "$status" in
    "success")
      emoji="✅"
      color="good"
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
      status_field_title="Notes"
      ;;
    "error")
      emoji="❌"
      color="danger"
      action_text="Theme Deployment Failed"
      status_field_title="Error"
      ;;
    *)
      emoji="ℹ️"
      color="#808080"
      action_text="Theme Status"
      ;;
  esac

  local truncated_message
  truncated_message=$(truncate_for_slack "$message" 700)

  local pr_value="<${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER}|#${PR_NUMBER}: ${PR_TITLE}>"
  local timestamp=$(date +%s)

  local payload
  payload=$(jq -n \
    --arg text "${emoji} Shopify ${action_text}" \
    --arg color "$color" \
    --arg repo "$GITHUB_REPOSITORY" \
    --arg pr "$pr_value" \
    --arg statusTitle "$status_field_title" \
    --arg statusValue "$truncated_message" \
    --arg themeId "$theme_id" \
    --arg preview "$preview_url" \
    --arg footer "Shopify Theme Preview" \
    --argjson ts "$timestamp" \
    '{
       text: $text,
       attachments: [
         {
           color: $color,
           fields: [
             {title: "Repository", value: $repo, short: true},
             {title: "PR", value: $pr, short: true}
           ],
           footer: $footer,
           ts: $ts
         }
       ]
     }
     | if $themeId != "" then (.attachments[0].fields += [{title: "Theme ID", value: $themeId, short: true}]) else . end
     | if $preview != "" then (.attachments[0].fields += [{title: "Preview URL", value: ("<" + $preview + "|View Preview>"), short: true}]) else . end
     | if $statusValue != "" then (.attachments[0].fields += [{title: $statusTitle, value: $statusValue, short: false}]) else . end'
  )

  curl -s -X POST -H 'Content-type: application/json' \
    --data "$payload" \
    "$SLACK_WEBHOOK_URL" >/dev/null || echo "⚠️ Failed to send Slack notification"
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
  THEME_ERRORS=""
  
  while [ $retry_count -lt $max_retries ]; do
    echo "📤 Upload attempt $((retry_count + 1)) of ${max_retries}..."
    
    local status=0
    set +e
    OUTPUT=$(shopify theme push \
      --theme "${theme_id}" \
      --nodelete \
      --no-color \
      --json 2>&1)
    status=$?
    set -e

    LAST_UPLOAD_OUTPUT="$OUTPUT"

    local parsed_json
    parsed_json=$(printf '%s' "$OUTPUT" | extract_theme_cli_json 2>/dev/null || echo "")

    if [ $status -eq 0 ]; then
      if [ -n "$parsed_json" ]; then
        local error_count
        error_count=$(echo "$parsed_json" | jq '(.theme.errors // {}) | length')
        local warning_message
        warning_message=$(echo "$parsed_json" | jq -r '.theme.warning // ""')

        if [ "$error_count" -eq 0 ]; then
          if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
            THEME_ERRORS="$warning_message"
            export THEME_ERRORS
          fi
          echo "✅ Theme updated successfully"
          return 0
        fi

        THEME_ERRORS=$(echo "$parsed_json" | jq -r '(.theme.errors // {}) | to_entries | map(.key + ": " + (.value | join(", "))) | join("\n")')
        [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$OUTPUT"
        retry_count=$max_retries
        break
      else
        echo "✅ Theme updated successfully"
        return 0
      fi
    else
      THEME_ERRORS="$OUTPUT"
    fi

    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      echo "⚠️ Upload failed, retrying in 3 seconds..."
      sleep 3
    fi
  done
  
  echo "❌ Failed to upload to theme after ${max_retries} attempts"
  echo "Last output: $LAST_UPLOAD_OUTPUT"
  return 1
}

# Function to create theme with retry on limit
create_theme_with_retry() {
  local theme_name="$1"
  local max_retries=3
  local attempt=0
  local limit_cleanup_attempted=false

  CREATED_THEME_ID=""
  THEME_ERRORS=""
  LAST_UPLOAD_OUTPUT=""

  while [ $attempt -lt $max_retries ]; do
    if [ -z "$CREATED_THEME_ID" ]; then
      echo "🎨 Creating new theme: ${theme_name} (attempt $((attempt + 1)))"

      local status=0
      set +e
      OUTPUT=$(shopify theme push \
        --unpublished \
        --theme "${theme_name}" \
        --nodelete \
        --no-color \
        --json 2>&1)
      status=$?
      set -e

      LAST_UPLOAD_OUTPUT="$OUTPUT"

      if echo "$OUTPUT" | grep -qi "limit\|maximum\|exceeded\|too many"; then
        echo "⚠️ Theme limit error detected"
        if [ "$limit_cleanup_attempted" = false ] && handle_theme_limit; then
          limit_cleanup_attempted=true
          echo "🔄 Retrying theme creation after cleanup..."
          attempt=$((attempt + 1))
          sleep 2
          continue
        fi

        THEME_ERRORS="Theme limit reached and older previews could not be removed automatically."
        post_error_comment "$THEME_ERRORS" ""
        send_slack_notification "error" "$THEME_ERRORS" "" ""
        return 1
      fi

      local parsed_json
      parsed_json=$(printf '%s' "$OUTPUT" | extract_theme_cli_json 2>/dev/null || echo "")

      if [ -n "$parsed_json" ]; then
        local parsed_theme_id
        parsed_theme_id=$(echo "$parsed_json" | jq -r '.theme.id // empty')
        [ "$parsed_theme_id" = "null" ] && parsed_theme_id=""
        if [ -n "$parsed_theme_id" ]; then
          CREATED_THEME_ID="$parsed_theme_id"
          THEME_ID="$CREATED_THEME_ID"
          export THEME_ID
          echo "✅ Theme created with ID: ${CREATED_THEME_ID}"
        fi

        local error_count
        error_count=$(echo "$parsed_json" | jq '(.theme.errors // {}) | length')
        local warning_message
        warning_message=$(echo "$parsed_json" | jq -r '.theme.warning // ""')

        if [ "$error_count" -gt 0 ]; then
          THEME_ERRORS=$(echo "$parsed_json" | jq -r '(.theme.errors // {}) | to_entries | map(.key + ": " + (.value | join(", "))) | join("\n")')
          [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$OUTPUT"

          cleanup_failed_theme "$CREATED_THEME_ID"
          post_error_comment "$THEME_ERRORS" "$CREATED_THEME_ID"

          local preview_url=""
          if [ -n "$CREATED_THEME_ID" ]; then
            local store_url="${SHOPIFY_FLAG_STORE}"
            store_url="${store_url#https://}"
            store_url="${store_url#http://}"
            store_url="${store_url%/}"
            preview_url="https://${store_url}?preview_theme_id=${CREATED_THEME_ID}"
          fi

          send_slack_notification "error" "Theme push errors:\n${THEME_ERRORS}" "$preview_url" "$CREATED_THEME_ID"
          return 1
        fi

        if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
          THEME_ERRORS="$warning_message"
          export THEME_ERRORS
          return 0
        fi

        if [ -n "$CREATED_THEME_ID" ]; then
          return 0
        fi
      fi

      attempt=$((attempt + 1))
      if [ $attempt -lt $max_retries ]; then
        echo "⚠️ Theme creation failed, retrying in 3 seconds..."
        sleep 3
      fi
    else
      if retry_theme_upload "$CREATED_THEME_ID"; then
        THEME_ID="$CREATED_THEME_ID"
        export THEME_ID
        return 0
      fi

      attempt=$((attempt + 1))
      if [ $attempt -lt $max_retries ]; then
        echo "⚠️ Upload to theme ${CREATED_THEME_ID} failed, retrying in 3 seconds..."
        sleep 3
      fi
    fi
  done

  echo "❌ Failed to create/upload theme after ${max_retries} attempts"
  echo "Last output: $LAST_UPLOAD_OUTPUT"

  if [ -n "$CREATED_THEME_ID" ]; then
    cleanup_failed_theme "$CREATED_THEME_ID"

    local final_message="$THEME_ERRORS"
    [ -z "$final_message" ] && final_message="$LAST_UPLOAD_OUTPUT"
    post_error_comment "$final_message" "$CREATED_THEME_ID"

    local store_url="${SHOPIFY_FLAG_STORE}"
    store_url="${store_url#https://}"
    store_url="${store_url#http://}"
    store_url="${store_url%/}"
    local preview_url="https://${store_url}?preview_theme_id=${CREATED_THEME_ID}"

    send_slack_notification "error" "Theme upload failed after retries." "$preview_url" "$CREATED_THEME_ID"
  else
    local fallback_message="$THEME_ERRORS"
    [ -z "$fallback_message" ] && fallback_message="$LAST_UPLOAD_OUTPUT"
    post_error_comment "$fallback_message" ""
    send_slack_notification "error" "$fallback_message" "" ""
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
  LAST_UPLOAD_OUTPUT="$UPDATE_OUTPUT"
  local update_parsed_json
  update_parsed_json=$(printf '%s' "$UPDATE_OUTPUT" | extract_theme_cli_json 2>/dev/null || echo "")
  local update_error_count=0
  local update_warning_message=""

  if [ -n "$update_parsed_json" ]; then
    update_error_count=$(echo "$update_parsed_json" | jq '(.theme.errors // {}) | length')
    update_warning_message=$(echo "$update_parsed_json" | jq -r '.theme.warning // ""')
  fi
  
  # Check for errors in update
  if [ $UPDATE_SUCCESS -ne 0 ] || [ "$update_error_count" -gt 0 ]; then
    echo "⚠️ Theme update encountered errors"
    if [ -n "$update_parsed_json" ]; then
      THEME_ERRORS=$(echo "$update_parsed_json" | jq -r '(.theme.errors // {}) | to_entries | map(.key + ": " + (.value | join(", "))) | join("\n")')
    fi
    [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$UPDATE_OUTPUT"

    echo "$UPDATE_OUTPUT"

    post_error_comment "${THEME_ERRORS}" "${EXISTING_THEME_ID}"
    
    STORE_URL="${SHOPIFY_FLAG_STORE}"
    STORE_URL="${STORE_URL#https://}"
    STORE_URL="${STORE_URL#http://}"
    STORE_URL="${STORE_URL%/}"
    PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${EXISTING_THEME_ID}"
    
    send_slack_notification "error" "Theme update failed: ${THEME_ERRORS}" "${PREVIEW_URL}" "${EXISTING_THEME_ID}"
    exit 1
  fi
  
  if [ -n "$update_warning_message" ] && [ "$update_warning_message" != "null" ]; then
    echo "⚠️ Theme updated with warnings"
    THEME_ERRORS="$update_warning_message"
    export THEME_ERRORS
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
