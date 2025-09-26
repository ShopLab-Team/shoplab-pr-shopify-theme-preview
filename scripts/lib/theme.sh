#!/bin/bash
# Theme management functions for Shopify theme deployment scripts

# Source common utilities if not already loaded
[[ -z "${COMMON_UTILS_LOADED}" ]] && source "${BASH_SOURCE%/*}/common.sh" && COMMON_UTILS_LOADED=1
[[ -z "${GITHUB_API_LOADED}" ]] && source "${BASH_SOURCE%/*}/github.sh" && GITHUB_API_LOADED=1
[[ -z "${SLACK_API_LOADED}" ]] && source "${BASH_SOURCE%/*}/slack.sh" && SLACK_API_LOADED=1

# Function to cleanup a failed theme
cleanup_failed_theme() {
  local theme_id=$1
  echo "🧹 Attempting to cleanup theme ${theme_id}..."
  
  if shopify theme delete --theme "${theme_id}" --force 2>&1 | grep -q "Success"; then
    echo "✅ Successfully deleted theme ${theme_id}"
    return 0
  else
    echo "❌ Failed to delete theme ${theme_id}"
    return 1
  fi
}

# Helper function: check if theme exists by name in Shopify store
check_theme_exists_by_name() {
  local theme_name="$1"
  local theme_list
  
  echo "🔍 Checking if theme with name '${theme_name}' exists in Shopify store..." >&2
  
  if ! theme_list=$(shopify theme list --json 2>/dev/null); then
    echo "⚠️ Could not retrieve theme list from Shopify"
    return 1
  fi
  
  # Look for exact theme name match
  local found_theme_id
  found_theme_id=$(echo "$theme_list" | node -e "
    const fs = require('fs');
    const data = fs.readFileSync(0, 'utf8');
    const name = process.argv[1];
    try {
      const obj = JSON.parse(data);
      let themes;
      // Handle both array and object formats
      if (Array.isArray(obj)) {
        themes = obj;
      } else if (obj && obj.themes) {
        themes = obj.themes;
      } else {
        themes = [];
      }
      // Log theme names for debugging
      if (themes.length > 0) {
        const themeNames = themes.map(t => t.name);
        console.error('Found ' + themes.length + ' themes: ' + JSON.stringify(themeNames));
      }
      const found = themes.find(t => t.name === name);
      if (found) {
        console.error('✅ Found matching theme: ' + found.name + ' (ID: ' + found.id + ')');
      } else {
        console.error('❌ No match found for: ' + name);
      }
      console.log(found?.id || '');
    } catch(e) {
      console.error('Error parsing theme list:', e.message);
      console.error('Data received:', data.substring(0, 200));
      console.log('');
    }
  " -- "$theme_name" 2>&1 | grep -v "^Found\|^✅\|^❌\|^Error parsing\|^Data received" || true)
  
  if [ -n "$found_theme_id" ] && [ "$found_theme_id" != "null" ]; then
    echo "✅ Found existing theme with name '${theme_name}' (ID: ${found_theme_id})" >&2
    echo "$found_theme_id"
    return 0
  fi
  
  return 1
}

# Function to handle theme limit errors
handle_theme_limit() {
  echo "🔍 Checking for old PR preview themes to clean up..."
  
  local theme_list
  if ! theme_list=$(shopify theme list --json 2>/dev/null); then
    echo "⚠️ Could not retrieve theme list"
    return 1
  fi

  # Try to parse the JSON and find old preview themes
  local old_preview_themes
  old_preview_themes=$(echo "$theme_list" | node -e "
    const data = require('fs').readFileSync(0, 'utf8');
    try {
      const parsed = JSON.parse(data);
      let themes = [];
      
      // Handle both direct array and object with themes property
      if (Array.isArray(parsed)) {
        themes = parsed;
      } else if (parsed.themes && Array.isArray(parsed.themes)) {
        themes = parsed.themes;
      }
      
      // Filter for PR preview themes (unpublished, matching our naming pattern)
      const previewThemes = themes.filter(t => 
        t.role === 'unpublished' && 
        (t.name.includes('PR-') || t.name.includes('FLASH-'))
      ).map(t => ({id: t.id, name: t.name, updated_at: t.updated_at}));
      
      // Sort by update date (oldest first)
      previewThemes.sort((a, b) => new Date(a.updated_at) - new Date(b.updated_at));
      
      console.log(JSON.stringify(previewThemes));
    } catch (error) {
      console.error('Error parsing theme list:', error);
      console.log('[]');
    }
  " 2>/dev/null)

  local themes_deleted=0
  if [ -n "$old_preview_themes" ] && [ "$old_preview_themes" != "[]" ]; then
    # Try to delete the oldest preview themes
    local theme_ids
    theme_ids=$(echo "$old_preview_themes" | parse_json "" "[*].id" | tr '\n' ' ')
    
    for theme_id in $theme_ids; do
      if [ $themes_deleted -ge 2 ]; then
        break  # Delete at most 2 themes
      fi
      
      local theme_name
      theme_name=$(echo "$old_preview_themes" | node -e "
        const themes = JSON.parse(require('fs').readFileSync(0, 'utf8'));
        const theme = themes.find(t => t.id == '$theme_id');
        console.log(theme ? theme.name : '');
      ")
      
      echo "🗑️ Attempting to delete old preview theme: ${theme_name} (ID: ${theme_id})"
      if cleanup_failed_theme "$theme_id"; then
        themes_deleted=$((themes_deleted + 1))
      fi
    done
  fi

  if [ $themes_deleted -gt 0 ]; then
    echo "✅ Deleted ${themes_deleted} old preview theme(s)"
    return 0
  else
    echo "⚠️ No old preview themes found to delete"
    return 1
  fi
}

# Function to post error comment on PR
post_error_comment() {
  local error_message=$1
  local theme_id=$2
  
  echo "💬 Posting error comment to PR..."
  
  # Clean error message for better readability  
  local cleaned_error
  cleaned_error=$(clean_for_slack "$error_message")
  
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

Your theme preview has been created but encountered errors during upload:

\`\`\`
${cleaned_error}
\`\`\`

### Theme Details:
- **Theme ID**: \`${theme_id}\`
- **Preview URL**: [View Preview](${PREVIEW_URL})
- **Admin URL**: [Theme Editor](https://${STORE_URL}/admin/themes/${theme_id}/editor)

**Note**: The theme may be missing files or functionality due to these errors. Please fix the issues and push your changes to update the preview.

<!-- SHOPIFY_THEME_ID: ${theme_id} -->
EOF
)
  else
    # Theme creation failed completely
    comment_body=$(cat <<EOF
## ❌ Shopify Theme Preview Failed

Failed to create theme preview due to the following errors:

\`\`\`
${cleaned_error}
\`\`\`

Please fix these issues and push your changes to trigger a new deployment.
EOF
)
  fi

  # Use the github_api function to post comment
  if post_pr_comment "$PR_NUMBER" "$comment_body"; then
    echo "✅ Error comment posted successfully"
  else
    echo "❌ Failed to post error comment"
  fi
}

# Function to upload theme to Shopify
upload_theme() {
  local theme_id=$1
  local include_json=${2:-true}  # Default to true for backward compatibility
  local status=0
  local parsed_json
  local error_count
  local warning_message
  
  THEME_ERRORS=""
  LAST_UPLOAD_OUTPUT=""
  
  # If we should not include JSON, add ignore flags
  if [ "$include_json" = "false" ]; then
    echo "📤 Uploading theme to ID: ${theme_id} (excluding JSON files)..."
    set +e
    OUTPUT=$(shopify theme push \
      --theme "$theme_id" \
      --nodelete \
      --no-color \
      --json \
      --ignore="*.json" 2>&1)
    status=$?
    set -e
  else
    echo "📤 Uploading theme to ID: ${theme_id}..."
    set +e
    OUTPUT=$(shopify theme push \
      --theme "$theme_id" \
      --nodelete \
      --no-color \
      --json 2>&1)
    status=$?
    set -e
  fi
  
  LAST_UPLOAD_OUTPUT="$OUTPUT"
  
  # Try to parse JSON response
  parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}$' | tail -1 || echo "")
  if [ -z "$parsed_json" ]; then
    parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}' | tail -1 || echo "")
  fi

  if [ $status -eq 0 ]; then
    if [ -n "$parsed_json" ]; then
      error_count=$(echo "$parsed_json" | extract_json_value "" "error_count")
      warning_message=$(echo "$parsed_json" | extract_json_value "" "warning")

      if [ "$error_count" -eq 0 ]; then
        if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
          THEME_ERRORS="$warning_message"
          export THEME_ERRORS
        fi
        echo "✅ Theme updated successfully"
        return 0
      else
        THEME_ERRORS=$(echo "$parsed_json" | extract_json_value "" "format_errors")
        [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$OUTPUT"
        echo "❌ Theme upload failed with validation errors"
        return 1
      fi
    else
      echo "✅ Theme updated successfully (no JSON response, assuming success)"
      return 0
    fi
  else
    THEME_ERRORS="$OUTPUT"
    # Check for "doesn't exist" or "not found" errors
    if echo "$OUTPUT" | grep -qi "doesn't exist\|not found"; then
      echo "❌ Theme ID ${theme_id} no longer exists on Shopify. Cannot update."
      return 1
    fi
    echo "❌ Theme upload failed"
    return 1
  fi
}

# Function to create theme (NO RETRY for validation errors)
create_theme_with_retry() {
  local theme_name="$1"
  local max_retries=1  # NO RETRIES except for rate limits
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
      
      echo "🔍 Checking theme creation output..."
      
      # First check if this is a rate limit error
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
        # Slack notification will be sent by deploy.sh
        return 1
      fi

      # Extract JSON from the output
      local parsed_json
      parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}$' | tail -1 || echo "")
      
      if [ -z "$parsed_json" ]; then
        parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}' | tail -1 || echo "")
      fi
      
      if [ -n "$parsed_json" ]; then
        echo "✅ Found JSON response from Shopify CLI"
        
        local parsed_theme_id
        parsed_theme_id=$(echo "$parsed_json" | extract_json_value "" "theme_id")
        [ "$parsed_theme_id" = "null" ] && parsed_theme_id=""
        if [ -n "$parsed_theme_id" ]; then
          CREATED_THEME_ID="$parsed_theme_id"
          THEME_ID="$CREATED_THEME_ID"
          export THEME_ID
          echo "✅ Theme created with ID: ${CREATED_THEME_ID}"
        fi

        # Check for errors in the JSON response
        local error_count
        error_count=$(echo "$parsed_json" | extract_json_value "" "error_count")
        local warning_message
        warning_message=$(echo "$parsed_json" | extract_json_value "" "warning")
        
        echo "📊 Theme creation result: error_count=${error_count}, has_warnings=$([ -n "$warning_message" ] && [ "$warning_message" != "null" ] && echo "yes" || echo "no")"

        if [ "$error_count" -gt 0 ]; then
          echo "❌ Theme was created with ${error_count} error(s)"
          THEME_ERRORS=$(echo "$parsed_json" | extract_json_value "" "format_errors")
          [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$OUTPUT"
          
          # ALWAYS cleanup the failed theme immediately
          if [ -n "$CREATED_THEME_ID" ]; then
            echo "🧹 Cleaning up theme ${CREATED_THEME_ID} that was created with errors..."
            if cleanup_failed_theme "$CREATED_THEME_ID"; then
              echo "✅ Failed theme ${CREATED_THEME_ID} has been removed"
              CREATED_THEME_ID=""
            else
              echo "⚠️ WARNING: Could not cleanup failed theme ${CREATED_THEME_ID}"
            fi
          fi
          
          # Exit immediately - NO RETRIES for validation errors
          post_error_comment "$THEME_ERRORS" ""
          # Slack notification will be sent by deploy.sh with cleanup status
          
          echo "🛑 Stopping - validation errors cannot be fixed by retrying"
          return 1
        fi

        if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
          echo "⚠️ Theme created with warnings: $warning_message"
          THEME_ERRORS="$warning_message"
          export THEME_ERRORS
          return 0
        fi

        if [ -n "$CREATED_THEME_ID" ]; then
          echo "✅ Theme created successfully without errors!"
          return 0
        fi
        
        # If we get here, no theme ID was found in the JSON
        echo "❌ ERROR: JSON response didn't contain a theme ID"
        echo "📝 Full JSON was: $parsed_json"
        # Try to extract it manually
        local manual_theme_id
        manual_theme_id=$(echo "$parsed_json" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        if [ -n "$manual_theme_id" ]; then
          echo "🔍 Manually extracted theme ID: $manual_theme_id"
          CREATED_THEME_ID="$manual_theme_id"
          THEME_ID="$CREATED_THEME_ID"
          export THEME_ID
          return 0
        fi
        # If we still can't get the ID, fail immediately
        THEME_ERRORS="Failed to extract theme ID from Shopify response"
        return 1
      else
        # No JSON found - check for rate limit
        if echo "$OUTPUT" | grep -qi "limit\|maximum\|exceeded\|too many"; then
          # Only retry for rate limit errors
          attempt=$((attempt + 1))
          if [ $attempt -lt $max_retries ]; then
            echo "⚠️ Rate limit detected, waiting 30 seconds before retry..."
            sleep 30
            continue
          fi
        fi
        
        echo "❌ Theme creation failed"
        THEME_ERRORS="Failed to create theme: $OUTPUT"
        return 1
      fi
    fi

    # Should not reach here
    break
  done

  echo "❌ Failed to create theme"
  [ -n "$LAST_UPLOAD_OUTPUT" ] && echo "Last output: $LAST_UPLOAD_OUTPUT"

  # Always try to cleanup any partially created theme
  if [ -n "$CREATED_THEME_ID" ]; then
    echo "🧹 Attempting to cleanup failed theme ${CREATED_THEME_ID}..."
    if cleanup_failed_theme "$CREATED_THEME_ID"; then
      echo "✅ Failed theme ${CREATED_THEME_ID} cleaned up"
    else
      echo "⚠️ WARNING: Could not cleanup failed theme ${CREATED_THEME_ID}"
    fi
  fi

  return 1
}

# Export functions for use in other scripts
export -f cleanup_failed_theme
export -f check_theme_exists_by_name
export -f handle_theme_limit
export -f post_error_comment
export -f upload_theme
export -f create_theme_with_retry
