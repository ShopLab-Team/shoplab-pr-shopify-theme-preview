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

# Escape special regex characters in theme name for grep patterns
THEME_NAME_ESCAPED=$(printf '%s' "$THEME_NAME" | sed 's/[][\.^$()|*+?{}]/\\&/g')

# Find theme ID from PR comments
echo "🔍 Looking for theme ID in PR comments..."
COMMENTS=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments")

# Parse comments for theme ID using the theme name
THEME_ID=""
while IFS= read -r line; do
  # Check if line contains our theme marker using fixed string matching
  if echo "$line" | grep -F "<!-- THEME_NAME:${THEME_NAME}:ID:" | grep -q ":END -->"; then
    # Extract the full theme data using escaped theme name for regex
    THEME_DATA=$(echo "$line" | grep -o "<!-- THEME_NAME:${THEME_NAME_ESCAPED}:ID:[0-9]*:END -->" 2>/dev/null || echo "")
    if [ -n "$THEME_DATA" ]; then
      # Extract just the ID number
      THEME_ID=$(echo "$THEME_DATA" | sed 's/.*:ID:\([0-9]*\):END.*/\1/')
      break
    fi
  fi
done <<< "$COMMENTS"

# Function to delete theme by ID
delete_theme_by_id() {
  local theme_id="$1"
  echo "🗑️ Attempting to delete theme with ID: ${theme_id}"
  
  # Use -t flag as per Shopify CLI docs and capture output
  DELETE_OUTPUT=$(shopify theme delete -t "${theme_id}" --force 2>&1)
  DELETE_EXIT_CODE=$?
  
  # Check if deletion was successful
  if [ $DELETE_EXIT_CODE -eq 0 ]; then
    echo "✅ Theme ${theme_id} deleted successfully"
    return 0
  elif echo "$DELETE_OUTPUT" | grep -q "Theme.*deleted"; then
    echo "✅ Theme ${theme_id} deleted successfully"
    return 0
  elif echo "$DELETE_OUTPUT" | grep -q "Theme.*not found"; then
    echo "⚠️ Theme ${theme_id} not found"
    return 1
  else
    echo "⚠️ Could not delete theme ${theme_id}"
    echo "Debug output: $DELETE_OUTPUT"
    return 1
  fi
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
    if delete_theme_by_id "$FOUND_THEME_ID"; then
      return 0
    else
      return 1
    fi
  else
    echo "ℹ️ No theme found with name: ${theme_name}"
    return 1
  fi
}

# Main deletion logic
DELETED=false

if [ -n "$THEME_ID" ]; then
  echo "✅ Found theme ID from PR comments: ${THEME_ID}"
  
  # Try to delete by ID first
  if delete_theme_by_id "$THEME_ID"; then
    echo "🎉 Theme deleted successfully using ID from comments"
    DELETED=true
  else
    echo "⚠️ Could not delete theme by ID, trying fallback search by name..."
    
    # Fallback: try to find and delete by exact name match
    if find_and_delete_by_name "$THEME_NAME"; then
      echo "🎉 Theme deleted successfully using name match"
      DELETED=true
    fi
  fi
else
  echo "⚠️ No theme ID found in PR comments, searching by name..."
  
  # Try to find and delete by exact name match
  if find_and_delete_by_name "$THEME_NAME"; then
    echo "🎉 Theme deleted successfully using name match"
    DELETED=true
  fi
fi

# Final status
if [ "$DELETED" = false ]; then
  echo "ℹ️ No theme was deleted (theme may have been manually deleted or never created)"
fi

echo "🎉 Cleanup complete!"
