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

if [ -n "$THEME_ID" ]; then
  echo "✅ Found theme ID to delete: ${THEME_ID}"
  
  # Verify theme exists before trying to delete
  echo "🔍 Verifying theme exists..."
  THEME_LIST=$(shopify theme list --json 2>/dev/null || echo "{}")
  
  if echo "$THEME_LIST" | grep -q "\"id\":${THEME_ID}"; then
    echo "📍 Theme found in store, proceeding with deletion..."
    
    # Delete the theme
    shopify theme delete --theme ${THEME_ID} --force 2>&1 | while IFS= read -r line; do
      # Filter out noisy output
      if [[ ! "$line" =~ "Deleting theme" ]]; then
        echo "$line"
      fi
    done
    
    echo "✅ Theme ${THEME_ID} deleted successfully"
  else
    echo "⚠️ Theme ${THEME_ID} not found in store (may have been manually deleted)"
  fi
else
  echo "ℹ️ No theme ID found in PR comments - nothing to delete"
fi

echo "🎉 Cleanup complete!"
