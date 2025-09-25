#!/bin/bash
set -e

# Deployment script for Shopify PR Theme Preview Action
# This script handles both creating new themes and updating existing ones

# Source library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" && COMMON_UTILS_LOADED=1
source "${SCRIPT_DIR}/lib/github.sh" && GITHUB_API_LOADED=1
source "${SCRIPT_DIR}/lib/slack.sh" && SLACK_API_LOADED=1
source "${SCRIPT_DIR}/lib/theme.sh" && THEME_API_LOADED=1

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

# Check for rebuild-theme label
HAS_REBUILD_LABEL="false"
if [ -n "$PR_LABELS" ]; then
  if echo "$PR_LABELS" | grep -q "rebuild-theme"; then
    HAS_REBUILD_LABEL="true"
    echo "🔄 Found 'rebuild-theme' label - will pull fresh settings from source theme"
  fi
fi

# Check for no-sync label
HAS_NO_SYNC_LABEL="false"
if [ -n "$PR_LABELS" ]; then
  if echo "$PR_LABELS" | grep -q "no-sync"; then
    HAS_NO_SYNC_LABEL="true"
    echo "⏭️ Found 'no-sync' label - will skip pulling settings from source theme"
  fi
fi

# Sanitize PR title for theme name - handle edge cases
if [ -z "$PR_TITLE" ]; then
  THEME_NAME="PR-${PR_NUMBER}"
else
  # First, try to extract any ticket/issue reference (like FLASH-123)
  ticket_ref=$(echo "$PR_TITLE" | grep -oE '\[?[A-Z]+-[0-9]+\]?' | head -1 | tr -d '[]')
  
  # Sanitize the title: keep alphanumeric, space, dash, underscore, dot, brackets
THEME_NAME=$(printf '%s' "$PR_TITLE" | \
  tr -cd '[:alnum:][:space:]-_.[]' | \
  sed -E 's/[[:space:]]+/ /g' | \
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
  cut -c1-50)
  
  # If sanitization resulted in empty string, use ticket reference or fallback
  if [ -z "$THEME_NAME" ]; then
    if [ -n "$ticket_ref" ]; then
      THEME_NAME="$ticket_ref"
    else
      THEME_NAME="PR-${PR_NUMBER}"
    fi
  fi
fi

# Ensure theme name is not empty and doesn't start/end with whitespace
THEME_NAME=$(echo "$THEME_NAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ -z "$THEME_NAME" ] && THEME_NAME="PR-${PR_NUMBER}"

echo "📝 Theme name: ${THEME_NAME}"

# Find existing theme information from PR comments
echo "🔍 Checking for existing theme..."

# Fetch comments and theme list in parallel for better performance
{
  COMMENTS=$(fetch_pr_comments "$PR_NUMBER") &
  COMMENTS_PID=$!
  
  THEME_LIST_JSON=$(shopify theme list --json 2>/dev/null) &
  THEME_LIST_PID=$!
} 2>/dev/null

# Wait for both operations to complete
wait $COMMENTS_PID $THEME_LIST_PID 2>/dev/null || true

# Extract theme ID from comments if exists
if [ -n "$COMMENTS" ]; then
  EXISTING_THEME_ID=$(echo "$COMMENTS" | extract_latest_theme_marker)
fi

# If we found a theme ID in comments, verify it still exists
if [ -n "$EXISTING_THEME_ID" ]; then
  echo "📋 Found theme ID ${EXISTING_THEME_ID} in PR comments"
  
  # Check if this theme actually exists in the Shopify store
  THEME_EXISTS=""
  if [ -n "$THEME_LIST_JSON" ]; then
    THEME_EXISTS=$(echo "$THEME_LIST_JSON" | node -e "
      const data = require('fs').readFileSync(0, 'utf8');
      const themeId = '$EXISTING_THEME_ID';
      try {
        const obj = JSON.parse(data);
        const themes = obj.themes || obj || [];
        const exists = Array.isArray(themes) ? themes.some(t => t.id == themeId) : false;
        console.log(exists ? 'true' : '');
      } catch(e) {
        console.log('');
      }
    " 2>/dev/null)
  fi
  
  if [ -z "$THEME_EXISTS" ]; then
    echo "⚠️ Theme ${EXISTING_THEME_ID} from comments no longer exists on the store!"
    
    # Try to find theme by exact name match as fallback
    if FOUND_THEME_ID=$(check_theme_exists_by_name "$THEME_NAME"); then
      echo "✅ Using theme ID ${FOUND_THEME_ID} found by name match"
      EXISTING_THEME_ID="$FOUND_THEME_ID"
    else
      echo "📝 No matching theme found by name either, will create new theme"
      EXISTING_THEME_ID=""
    fi
  else
    echo "✅ Theme ${EXISTING_THEME_ID} confirmed to exist on store"
  fi
else
  echo "📝 No existing theme found in comments"
  
  # Check if a theme with this exact name already exists in the store
  if FOUND_THEME_ID=$(check_theme_exists_by_name "$THEME_NAME"); then
    echo "✅ Found existing theme by name match, will update it"
    EXISTING_THEME_ID="$FOUND_THEME_ID"
  else
    echo "📝 No existing theme found by name, will create new one"
  fi
fi

# Run build command if provided
if [ -n "${BUILD_COMMAND}" ]; then
  echo "🔨 Running build command: ${BUILD_COMMAND}"
  eval "${BUILD_COMMAND}"
  echo "✅ Build completed"
fi

# Deploy or update theme
if [ -n "${EXISTING_THEME_ID}" ]; then
  echo "🔄 Preparing to update existing theme ID: ${EXISTING_THEME_ID}"
  
  # Check if rebuild-theme label is present - if so, pull settings first
  if [ "$HAS_REBUILD_LABEL" = "true" ]; then
    echo "🔄 'rebuild-theme' label detected - pulling fresh settings from source theme"
    if [ -n "${SOURCE_THEME_ID}" ]; then
      echo "📥 Pulling settings from theme ID: ${SOURCE_THEME_ID}"
      THEME_SELECTOR="--theme ${SOURCE_THEME_ID}"
    else
      echo "📥 No source theme specified, pulling from live theme"
      THEME_SELECTOR="--live"
    fi
    
    echo "⬇️ Pulling JSON configuration files (excluding settings_schema.json)..."
    
    # Pull only JSON files to preserve settings, but exclude settings_schema.json which must come from codebase
    if ! shopify theme pull $THEME_SELECTOR --only="*.json" --ignore="config/settings_schema.json" --no-color 2>&1; then
      echo "⚠️ Warning: Could not pull settings from source theme"
    else
      echo "✅ Settings pulled successfully (settings_schema.json preserved from codebase)"
    fi
  else
    echo "💾 Preserving existing theme settings (no rebuild-theme label)"
  fi
  
  # Upload to existing theme
  THEME_ID="${EXISTING_THEME_ID}"
  export THEME_ID
  
  if upload_theme "${EXISTING_THEME_ID}"; then
    echo "✅ Theme ${EXISTING_THEME_ID} updated successfully!"
    
    # Get preview URL for existing theme
    STORE_URL="${SHOPIFY_FLAG_STORE}"
    STORE_URL="${STORE_URL#https://}"
    STORE_URL="${STORE_URL#http://}"
    STORE_URL="${STORE_URL%/}"
    PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${EXISTING_THEME_ID}"
    
    # Post success comment with existing theme
    COMMENT_BODY="## ✅ Shopify Theme Preview Updated

Your theme preview has been updated successfully!

### Theme Details:
- **Theme ID**: \`${EXISTING_THEME_ID}\`
- **Preview URL**: [View Preview](${PREVIEW_URL})
- **Admin URL**: [Theme Editor](https://${STORE_URL}/admin/themes/${EXISTING_THEME_ID}/editor)

<!-- SHOPIFY_THEME_ID: ${EXISTING_THEME_ID} -->"

    if [ -n "$THEME_ERRORS" ]; then
      # Clean error message for display
      CLEANED_ERRORS=$(clean_for_slack "$THEME_ERRORS")
      COMMENT_BODY="${COMMENT_BODY}

### ⚠️ Warnings:
\`\`\`
${CLEANED_ERRORS}
\`\`\`"
    fi

    # Post comment
    if post_pr_comment "$PR_NUMBER" "$COMMENT_BODY"; then
      echo "✅ Success comment posted"
    else
      echo "⚠️ Failed to post success comment"
    fi
    
    # No Slack notification for theme updates
    
    # Set outputs for GitHub Action
    echo "theme-id=${EXISTING_THEME_ID}" >> "$GITHUB_OUTPUT"
    echo "preview-url=${PREVIEW_URL}" >> "$GITHUB_OUTPUT"
    
    exit 0
  else
    # Update failed - check if theme doesn't exist
    if echo "$LAST_UPLOAD_OUTPUT" | grep -qi "doesn't exist\|not found\|Theme #${EXISTING_THEME_ID} does not exist"; then
      echo "❌ Theme ${EXISTING_THEME_ID} no longer exists! Will create a new one..."
      EXISTING_THEME_ID=""
      # Fall through to create new theme
    else
      # Update failed for other reasons
      echo "❌ Failed to update existing theme"
      post_error_comment "$THEME_ERRORS" "$EXISTING_THEME_ID"
      
      # No Slack notification for theme update failures
      exit 1
    fi
  fi
fi

# Create new theme (only if no existing theme or update failed due to non-existence)
# Only pull JSON configuration if no-sync label is NOT present
if [ "$HAS_NO_SYNC_LABEL" = "false" ]; then
  echo "📥 Pulling JSON configuration from live theme before creating new theme..."

  # Determine which theme to pull settings from
  if [ -n "${SOURCE_THEME_ID}" ]; then
    echo "📥 Pulling settings from theme ID: ${SOURCE_THEME_ID}"
    THEME_SELECTOR="--theme ${SOURCE_THEME_ID}"
  else
    echo "📥 No source theme specified, pulling from live theme"
    THEME_SELECTOR="--live"
  fi

  echo "⬇️ Pulling JSON configuration files (excluding settings_schema.json)..."

  # Pull only JSON files to get current settings, but exclude settings_schema.json which must come from codebase
  if ! shopify theme pull $THEME_SELECTOR --only="*.json" --ignore="config/settings_schema.json" --no-color 2>&1; then
    echo "⚠️ Warning: Could not pull settings from source theme"
  else
    echo "✅ Settings pulled successfully (settings_schema.json preserved from codebase)"
  fi
else
  echo "⏭️ Skipping JSON configuration pull due to 'no-sync' label"
fi

if create_theme_with_retry "${THEME_NAME}"; then
  echo "🎉 Theme created and deployed successfully!"
  
  # Get preview URL
  STORE_URL="${SHOPIFY_FLAG_STORE}"
  STORE_URL="${STORE_URL#https://}"
  STORE_URL="${STORE_URL#http://}"
  STORE_URL="${STORE_URL%/}"
  PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${CREATED_THEME_ID}"
  
  # Post success comment
  COMMENT_BODY="## ✅ Shopify Theme Preview Created

Your theme preview has been created successfully!

### Theme Details:
- **Theme ID**: \`${CREATED_THEME_ID}\`
- **Preview URL**: [View Preview](${PREVIEW_URL})
- **Admin URL**: [Theme Editor](https://${STORE_URL}/admin/themes/${CREATED_THEME_ID}/editor)

<!-- SHOPIFY_THEME_ID: ${CREATED_THEME_ID} -->"

  if [ -n "$THEME_ERRORS" ]; then
    # Clean error message for display
    CLEANED_ERRORS=$(clean_for_slack "$THEME_ERRORS")
    COMMENT_BODY="${COMMENT_BODY}

### ⚠️ Warnings:
\`\`\`
${CLEANED_ERRORS}
\`\`\`"
  fi

  # Post comment
  if post_pr_comment "$PR_NUMBER" "$COMMENT_BODY"; then
    echo "✅ Success comment posted"
  else
    echo "⚠️ Failed to post success comment"
  fi
  
  # Send Slack notification
  if [ -n "$THEME_ERRORS" ]; then
    send_slack_notification "warning" "Theme created with warnings:\n${CLEANED_ERRORS}" "$PREVIEW_URL" "$CREATED_THEME_ID"
  else
    send_slack_notification "success" "Theme created successfully!" "$PREVIEW_URL" "$CREATED_THEME_ID"
  fi
  
  # Set outputs for GitHub Action
  echo "theme-id=${CREATED_THEME_ID}" >> "$GITHUB_OUTPUT"
  echo "preview-url=${PREVIEW_URL}" >> "$GITHUB_OUTPUT"
  
  exit 0
else
  echo "❌ Failed to create theme"
  
  # Always try to cleanup any partially created theme
  if [ -n "$CREATED_THEME_ID" ]; then
    echo "🧹 Attempting to cleanup failed theme ${CREATED_THEME_ID}..."
    if cleanup_failed_theme "$CREATED_THEME_ID"; then
      echo "✅ Failed theme ${CREATED_THEME_ID} cleaned up"
      
      # Post error without theme ID since we cleaned it up
      post_error_comment "$THEME_ERRORS" ""
      
      # Adjust error message to indicate cleanup was successful
      cleaned_errors=$(clean_for_slack "$THEME_ERRORS")
      send_slack_notification "error" "Theme creation failed:\n${cleaned_errors}\n\nThe failed theme has been cleaned up." "" ""
    else
      echo "⚠️ WARNING: Could not cleanup failed theme ${CREATED_THEME_ID}"
      
      # Post error with theme ID since it still exists
      post_error_comment "$THEME_ERRORS" "$CREATED_THEME_ID"
      
      # Include preview URL in Slack notification since theme exists
      preview_url=""
      if [ -n "$CREATED_THEME_ID" ]; then
        store_url="${SHOPIFY_FLAG_STORE}"
        store_url="${store_url#https://}"
        store_url="${store_url#http://}"
        store_url="${store_url%/}"
        preview_url="https://${store_url}?preview_theme_id=${CREATED_THEME_ID}"
      fi
      
      cleaned_errors=$(clean_for_slack "$THEME_ERRORS")
      send_slack_notification "error" "Theme creation failed:\n${cleaned_errors}\n\n⚠️ Failed theme ${CREATED_THEME_ID} could not be cleaned up - manual cleanup required!" "$preview_url" "$CREATED_THEME_ID"
    fi
  else
    # No theme was created at all
    post_error_comment "$THEME_ERRORS" ""
    
    cleaned_errors=$(clean_for_slack "$THEME_ERRORS")
    send_slack_notification "error" "Theme creation failed:\n${cleaned_errors}" "" ""
  fi
  
  exit 1
fi
