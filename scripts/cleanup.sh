#!/bin/bash
set -e

# Cleanup script for Shopify PR Theme Preview Action
# This script deletes the theme when a PR is closed or merged

# Source library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" && COMMON_UTILS_LOADED=1

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

LAST_DELETE_OUTPUT=""
LAST_FOUND_THEME_ID=""

# Function to make GitHub API calls
github_api() {
  local endpoint=$1
  local method=${2:-GET}
  
  curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com${endpoint}"
}

# Helper function: extract the most recent theme marker from PR comments
extract_latest_theme_marker() {
  # Read JSON from stdin and process it with Node.js
  node <<'NODE'
const fs = require('fs');
const data = fs.readFileSync(0, 'utf8');  // Read from stdin

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
// Look for both old and new marker formats
const oldMarkerRegex = /<!-- THEME_NAME:(.+?):ID:(\d+):END -->/g;
const newMarkerRegex = /<!-- SHOPIFY_THEME_ID: (\d+) -->/g;

for (const comment of comments) {
  if (!comment || typeof comment.body !== "string") {
    continue;
  }

  // Check for old format markers
  let match;
  while ((match = oldMarkerRegex.exec(comment.body)) !== null) {
    markers.push({
      name: match[1],
      id: match[2],
      timestamp: comment.updated_at || comment.created_at || ""
    });
  }
  
  // Check for new format markers (SHOPIFY_THEME_ID)
  while ((match = newMarkerRegex.exec(comment.body)) !== null) {
    markers.push({
      name: null,  // New format doesn't include name
      id: match[1],
      timestamp: comment.updated_at || comment.created_at || ""
    });
  }
}

if (!markers.length) {
  process.exit(0);
}

// Sort by timestamp (most recent last)
markers.sort((a, b) => {
  if (a.timestamp && b.timestamp) {
    return new Date(b.timestamp) - new Date(a.timestamp);
  }
  if (a.timestamp) {
    return 1;
  }
  if (b.timestamp) {
    return -1;
  }
  return 0;
});

const latest = markers[0];  // Get the most recent (first after reverse sort)
if (latest.name) {
  process.stdout.write(`${latest.name}|${latest.id}`);
} else {
  // For new format, just return the ID
  process.stdout.write(`|${latest.id}`);
}
NODE
}

# Sanitize PR title for theme name (must match deploy.sh logic)
THEME_NAME=$(printf '%s' "$PR_TITLE" | \
  tr -cd '[:alnum:][:space:]-_.[]' | \
  sed -E 's/[[:space:]]+/ /g' | \
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
  cut -c1-50)

echo "📝 Looking for theme associated with this PR (default name: ${THEME_NAME})"

echo "🔍 Looking for theme marker in PR comments..."
COMMENTS=$(github_api "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100")

THEME_ID=""
THEME_NAME_FROM_COMMENT=""

# Suppress broken pipe error when Node exits early (happens when no markers found)
THEME_MARKER=$(printf '%s' "$COMMENTS" 2>/dev/null | extract_latest_theme_marker || true)

if [ -n "$THEME_MARKER" ]; then
  THEME_NAME_FROM_COMMENT=${THEME_MARKER%|*}
  THEME_ID=${THEME_MARKER##*|}
  if [ -n "$THEME_NAME_FROM_COMMENT" ]; then
    echo "✅ Found theme marker in PR comments (name: ${THEME_NAME_FROM_COMMENT}, ID: ${THEME_ID})"
  else
    echo "✅ Found theme ID in PR comments: ${THEME_ID}"
  fi
else
  echo "ℹ️ No theme marker found in PR comments"
fi

# Function to delete theme by ID
delete_theme_by_id() {
  local theme_id="$1"
  echo "🗑️ Attempting to delete theme with ID: ${theme_id}"
  
  local output=""
  local status=0
  set +e
  output=$(shopify theme delete -t "${theme_id}" --force 2>&1)
  status=$?
  set -e
  LAST_DELETE_OUTPUT="$output"
  
  if [ $status -eq 0 ]; then
    echo "✅ Theme ${theme_id} deleted successfully"
    LAST_FOUND_THEME_ID="$theme_id"
    return 0
  fi
  
  if echo "$output" | grep -qi "No themes" || echo "$output" | grep -qi "not found"; then
    echo "⚠️ Theme ${theme_id} not found"
    return 2
  fi
  
  echo "⚠️ Could not delete theme ${theme_id}"
  echo "Debug output: $output"
  return 1
}

# Function to find and delete theme by name
find_and_delete_by_name() {
  local theme_name="$1"
  local label="${2:-exact name match}"
  echo "🔍 Searching for theme by exact name match (${label}): ${theme_name}"
  
  # Get list of all themes. Stderr is kept apart so warnings (e.g. Node deprecations)
  # don't break the JSON, and is only shown when the command fails.
  local list_stderr
  list_stderr=$(mktemp)
  if ! THEME_LIST=$(shopify theme list --json 2>"$list_stderr"); then
    echo "⚠️ Could not list themes on the store:"
    cat "$list_stderr"
    rm -f "$list_stderr"
    return 1
  fi
  rm -f "$list_stderr"

  # Find an unpublished theme with this exact name. CLI 5.x prints {"themes":[...]},
  # older versions a bare array. Live and development themes are never matched.
  FOUND_THEME_ID=$(echo "$THEME_LIST" | node -e '
    let data = "";
    process.stdin.on("data", chunk => data += chunk);
    process.stdin.on("end", () => {
      try {
        const parsed = JSON.parse(data);
        const themes = Array.isArray(parsed) ? parsed : (parsed && parsed.themes) || [];
        console.error("ℹ️ Store has " + themes.length + " themes");
        const theme = themes.find(t => t.name === process.argv[1] && t.role === "unpublished");
        if (theme && theme.id) {
          process.stdout.write(String(theme.id));
        }
      } catch (e) {
        console.error("⚠️ Could not parse theme list: " + data.substring(0, 200));
      }
    });' "$theme_name" || echo "")
  
  if [ -n "$FOUND_THEME_ID" ]; then
    echo "✅ Found theme by name with ID: ${FOUND_THEME_ID}"
    if delete_theme_by_id "$FOUND_THEME_ID"; then
      return 0
    else
      return $?
    fi
  else
    echo "ℹ️ No unpublished theme found with name: ${theme_name}"
    return 1
  fi
}

# Main deletion logic
DELETED=false
DELETED_THEME_ID=""
DELETED_THEME_NAME=""

if [ -n "$THEME_ID" ]; then
  echo "✅ Found theme ID from PR comments: ${THEME_ID}"
  if [ -n "$THEME_NAME_FROM_COMMENT" ]; then
    echo "ℹ️ Comment recorded theme name: ${THEME_NAME_FROM_COMMENT}"
  fi

  if delete_theme_by_id "$THEME_ID"; then
    echo "🎉 Theme deleted successfully using ID from comments"
    DELETED=true
    DELETED_THEME_ID="$THEME_ID"
    DELETED_THEME_NAME="${THEME_NAME_FROM_COMMENT:-$THEME_NAME}"
  else
    delete_status=$?
    if [ $delete_status -ne 2 ]; then
      echo "$LAST_DELETE_OUTPUT"
    fi
    echo "⚠️ Could not delete theme by ID, attempting fallback search..."
  fi
else
  echo "⚠️ No theme ID found in PR comments"
fi

if [ "$DELETED" = false ] && [ -n "$THEME_NAME_FROM_COMMENT" ]; then
  LAST_FOUND_THEME_ID=""
  if find_and_delete_by_name "$THEME_NAME_FROM_COMMENT" "comment marker"; then
    echo "🎉 Theme deleted successfully using name from comment marker"
    DELETED=true
    DELETED_THEME_ID=${LAST_FOUND_THEME_ID:-$DELETED_THEME_ID}
    DELETED_THEME_NAME="$THEME_NAME_FROM_COMMENT"
  fi
fi

if [ "$DELETED" = false ] && { [ -z "$THEME_NAME_FROM_COMMENT" ] || [ "$THEME_NAME_FROM_COMMENT" != "$THEME_NAME" ]; }; then
  # As a final fallback, try the sanitized PR title (in case the PR title changed)
  LAST_FOUND_THEME_ID=""
  if find_and_delete_by_name "$THEME_NAME" "sanitized PR title"; then
    echo "🎉 Theme deleted successfully using sanitized PR title"
    DELETED=true
    DELETED_THEME_ID=${LAST_FOUND_THEME_ID:-$DELETED_THEME_ID}
    if [ -z "$DELETED_THEME_NAME" ]; then
      DELETED_THEME_NAME="$THEME_NAME"
    fi
  fi
fi

# Final status
if [ "$DELETED" = false ]; then
  echo "ℹ️ No theme was deleted (theme may have been manually deleted or never created)"
else
  IDENTIFIER="${DELETED_THEME_ID:-$DELETED_THEME_NAME}"
  echo "✅ Theme ${IDENTIFIER} deleted successfully"
fi

echo "🎉 Cleanup complete!"
