#!/bin/bash
set -e

# Cleanup script for Shopify PR Theme Preview Action
# This script deletes the theme when a PR is closed or merged

echo "🧹 Starting Shopify PR Theme cleanup..."

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

# Function to make GitHub API calls
github_api() {
  local endpoint=$1
  local method=${2:-GET}
  
  curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com${endpoint}"
}

# Sanitize PR title for theme name (must match deploy.sh logic)
THEME_NAME=$(printf '%s' "$PR_TITLE" | \
  tr -cd '[:alnum:][:space:]-_.[]' | \
  sed -E 's/[[:space:]]+/ /g' | \
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
  cut -c1-50)

echo "📝 Looking for theme: ${THEME_NAME}"

# Find theme ID from PR comments
echo "🔍 Looking for theme ID in PR comments..."
COMMENTS=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments")

# Parse comments for theme ID using the theme name
THEME_ID=""
while IFS= read -r line; do
  if echo "$line" | grep -q "<!-- THEME_NAME:${THEME_NAME}:ID:[0-9]*:END -->"; then
    THEME_DATA=$(echo "$line" | grep -o "<!-- THEME_NAME:${THEME_NAME}:ID:[0-9]*:END -->")
    THEME_ID=$(echo "$THEME_DATA" | sed "s/<!-- THEME_NAME:${THEME_NAME}:ID:\([0-9]*\):END -->/\1/")
    break
  fi
done <<< "$COMMENTS"

# Function to delete theme by ID
delete_theme_by_id() {
  local theme_id=$1
  echo "🗑️ Attempting to delete theme with ID: ${theme_id}"
  
  # Try to delete directly first (fastest approach)
  if shopify theme delete --theme ${theme_id} --force 2>&1 | grep -q "Theme deleted"; then
    echo "✅ Theme ${theme_id} deleted successfully"
    return 0
  fi
  
  return 1
}

# Function to find and delete theme by name
find_and_delete_by_name() {
  local theme_name="$1"
  echo "🔍 Searching for theme by exact name match: ${theme_name}"
  
  # Get list of all themes
  THEME_LIST=$(shopify theme list --json 2>/dev/null || echo "[]")
  
  # Try to find theme by exact name match using Node.js for JSON parsing
  FOUND_THEME_ID=$(echo "$THEME_LIST" | node -e '
    let data = "";
    process.stdin.on("data", chunk => data += chunk);
    process.stdin.on("end", () => {
      try {
        const themes = JSON.parse(data);
        if (Array.isArray(themes)) {
          const theme = themes.find(t => t.name === process.argv[1]);
          if (theme && theme.id) {
            process.stdout.write(String(theme.id));
          }
        }
      } catch (e) {
        // Silent fail
      }
    });' "$theme_name" 2>/dev/null || echo "")
  
  if [ -n "$FOUND_THEME_ID" ]; then
    echo "✅ Found theme by name with ID: ${FOUND_THEME_ID}"
    delete_theme_by_id "$FOUND_THEME_ID"
    return $?
  fi
  
  return 1
}

if [ -n "$THEME_ID" ]; then
  echo "✅ Found theme ID from PR comments: ${THEME_ID}"
  
  # Try to delete by ID first
  if delete_theme_by_id "$THEME_ID"; then
    echo "🎉 Theme deleted using ID from comments"
  else
    echo "⚠️ Could not delete theme by ID, trying fallback search by name..."
    
    # Fallback: try to find and delete by exact name match
    if find_and_delete_by_name "$THEME_NAME"; then
      echo "🎉 Theme deleted using name match"
    else
      echo "ℹ️ Theme not found (may have been manually deleted or never created)"
    fi
  fi
else
  echo "⚠️ No theme ID found in PR comments, searching by name..."
  
  # Try to find and delete by exact name match
  if find_and_delete_by_name "$THEME_NAME"; then
    echo "🎉 Theme deleted using name match"
  else
    echo "ℹ️ No theme found with name: ${THEME_NAME}"
  fi
fi

echo "🎉 Cleanup complete!"
