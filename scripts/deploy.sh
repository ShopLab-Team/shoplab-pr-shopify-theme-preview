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
EXISTING_COMMENT_ID=""

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

# Function to find and delete the oldest theme from open PRs
handle_theme_limit() {
  echo "⚠️ Theme limit reached, searching for oldest theme to remove..."
  
  # Get all open PRs
  OPEN_PRS=$(github_api "/repos/${GITHUB_REPOSITORY}/pulls?state=open&sort=updated&direction=asc&per_page=100")
  
  # Arrays to store PR info and theme IDs
  declare -a PR_NUMBERS
  declare -a PR_THEME_IDS
  declare -a PR_THEME_NAMES
  declare -a PR_UPDATED_DATES
  
  # Parse each PR to find themes
  echo "$OPEN_PRS" | jq -r '.[] | @json' | while IFS= read -r pr_json; do
    pr_number=$(echo "$pr_json" | jq -r '.number')
    pr_updated=$(echo "$pr_json" | jq -r '.updated_at')
    
    # Skip current PR
    if [ "$pr_number" = "$PR_NUMBER" ]; then
      continue
    fi
    
    # Check if PR has preserve-theme label
    pr_labels=$(echo "$pr_json" | jq -r '.labels[].name' 2>/dev/null)
    if echo "$pr_labels" | grep -q "preserve-theme"; then
      echo "  Skipping PR #${pr_number} (has preserve-theme label)"
      continue
    fi
    
    # Get comments for this PR
    pr_comments=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments")
    
    # Look for theme ID in comments
    theme_id=""
    theme_name=""
    while IFS= read -r line; do
      if echo "$line" | grep -F "<!-- THEME_NAME:" | grep -q ":END -->"; then
        # Extract theme ID
        theme_data=$(echo "$line" | grep -o "<!-- THEME_NAME:.*:ID:[0-9]*:END -->" 2>/dev/null || echo "")
        if [ -n "$theme_data" ]; then
          theme_id=$(echo "$theme_data" | sed 's/.*:ID:\([0-9]*\):END.*/\1/')
          theme_name=$(echo "$theme_data" | sed 's/<!-- THEME_NAME:\(.*\):ID:.*:END -->/\1/')
          if [ -n "$theme_id" ]; then
            echo "  Found theme ${theme_id} in PR #${pr_number} (updated: ${pr_updated})"
            # Return the values for processing
            echo "FOUND_THEME:${pr_number}:${theme_id}:${theme_name}:${pr_updated}"
            break 2  # Break both loops - we found our oldest theme
          fi
        fi
      fi
    done <<< "$pr_comments"
  done | while IFS=: read -r marker pr_num theme_id theme_name pr_updated; do
    if [ "$marker" = "FOUND_THEME" ]; then
      echo "🗑️ Deleting oldest theme ${theme_id} from PR #${pr_num}"
      
      # Delete the theme
      shopify theme delete -t "${theme_id}" --force 2>&1 | grep -v "Deleting theme" || true
      
      # Post comment on that PR
      COMMENT_BODY=$(cat <<EOF
## ⚠️ Theme Auto-Removed Due to Store Limit

Your preview theme was automatically deleted to make room for newer PRs (Shopify limit: 20 themes).

**To recreate your preview theme:**
- Add the label \`rebuild-theme\` to this PR
- Or push a new commit

The theme will be automatically recreated.
EOF
)
      
      ESCAPED_BODY=$(echo "$COMMENT_BODY" | jq -Rs .)
      github_api "/repos/${GITHUB_REPOSITORY}/issues/${pr_num}/comments" "POST" "{\"body\":${ESCAPED_BODY}}"
      
      echo "✅ Oldest theme deleted from PR #${pr_num}"
      return 0
    fi
  done
  
  echo "⚠️ No deletable themes found (all may have preserve-theme label)"
  return 1
}

# Function to create theme with retry on limit
create_theme_with_retry() {
  local theme_name="$1"
  local max_retries=3
  local retry_count=0
  
  while [ $retry_count -lt $max_retries ]; do
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
    
    # Try to extract theme ID
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
      echo "✅ Theme created with ID: ${THEME_ID}"
      # Export THEME_ID so it's available to the caller
      export THEME_ID
      return 0
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      echo "⚠️ Theme creation failed, retrying in 3 seconds..."
      sleep 3
    fi
  done
  
  echo "❌ Failed to create theme after ${max_retries} attempts"
  echo "Last output: $OUTPUT"
  return 1
}

# Sanitize PR title for theme name
THEME_NAME=$(printf '%s' "$PR_TITLE" | \
  tr -cd '[:alnum:][:space:]-_.[]' | \
  sed -E 's/[[:space:]]+/ /g' | \
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
  cut -c1-50)

echo "📝 Theme name: ${THEME_NAME}"

# Escape special regex characters in theme name for grep patterns
THEME_NAME_ESCAPED=$(printf '%s' "$THEME_NAME" | sed 's/[][\.^$()|*+?{}]/\\&/g')

# Find existing theme ID from PR comments
echo "🔍 Checking for existing theme..."
COMMENTS=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments")

# Parse comments for theme ID using the theme name
while IFS= read -r line; do
  # Check if line contains our theme marker using fixed string matching
  if echo "$line" | grep -F "<!-- THEME_NAME:${THEME_NAME}:ID:" | grep -q ":END -->"; then
    # Extract the full theme data using escaped theme name for regex
    THEME_DATA=$(echo "$line" | grep -o "<!-- THEME_NAME:${THEME_NAME_ESCAPED}:ID:[0-9]*:END -->" 2>/dev/null || echo "")
    if [ -n "$THEME_DATA" ]; then
      # Extract just the ID number
      EXISTING_THEME_ID=$(echo "$THEME_DATA" | sed 's/.*:ID:\([0-9]*\):END.*/\1/')
      break
    fi
  fi
done <<< "$COMMENTS"

if [ -n "$EXISTING_THEME_ID" ]; then
  echo "✅ Found existing theme ID: ${EXISTING_THEME_ID}"
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
  
  # Update existing theme, excluding JSON files to preserve settings
  shopify theme push \
    --theme "${EXISTING_THEME_ID}" \
    --nodelete \
    --no-color \
    --ignore "templates/*.json" \
    --ignore "sections/*.json" \
    --ignore "config/settings_data.json" \
    --ignore "locales/*.json" \
    --ignore "snippets/*.json" \
    --ignore "*.json" 2>&1 | while IFS= read -r line; do
      # Filter out noisy output but keep important messages
      if [[ ! "$line" =~ "Pushing theme files to" ]] && \
         [[ ! "$line" =~ "Theme pushed successfully" ]]; then
        echo "$line"
      fi
    done
  
  THEME_ID="${EXISTING_THEME_ID}"
  echo "✅ Theme updated successfully"
  
else
  # Pull settings from source theme (only on initial creation)
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
  
  # Use the retry function to create theme
  if create_theme_with_retry "${THEME_NAME}"; then
    # THEME_ID is set by the function
    echo "🎆 Theme creation successful!"
  else
    echo "❌ Failed to create theme"
    exit 1
  fi
  
  # Generate preview URL
  STORE_URL="${SHOPIFY_FLAG_STORE}"
  STORE_URL="${STORE_URL#https://}"
  STORE_URL="${STORE_URL#http://}"
  STORE_URL="${STORE_URL%/}"
  PREVIEW_URL="https://${STORE_URL}?preview_theme_id=${THEME_ID}"
  
  echo "🔗 Preview URL: ${PREVIEW_URL}"
  
  # Create the comment body with proper JSON escaping
  COMMENT_BODY=$(cat <<EOF
## 🚀 Shopify Theme Preview

**Preview your changes:** ${PREVIEW_URL}

**Theme:** ${THEME_NAME}  
**Theme ID:** \`${THEME_ID}\`

This preview theme will be automatically deleted when the PR is closed or merged.

<!-- THEME_NAME:${THEME_NAME}:ID:${THEME_ID}:END -->
EOF
)
  
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
fi

# Output theme ID for other steps
echo "theme-id=${THEME_ID}" >> $GITHUB_OUTPUT

echo "🎉 Deployment complete!"
