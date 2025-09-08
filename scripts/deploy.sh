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
  
  echo "🎨 Creating new theme: ${THEME_NAME}"
  
  # Create new theme - capture JSON output
  OUTPUT=$(shopify theme push \
    --unpublished \
    --theme "${THEME_NAME}" \
    --nodelete \
    --no-color \
    --json 2>&1)
  
  # Extract theme ID using Node.js
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
        } else {
          process.stderr.write("Could not extract theme ID from output");
          process.exit(1);
        }
      }
    });
  ')
  
  if [ -z "${THEME_ID}" ] || [ "${THEME_ID}" == "null" ]; then
    echo "❌ Error: Could not extract theme ID from output"
    echo "Output was:"
    echo "$OUTPUT"
    exit 1
  fi
  
  echo "✅ Theme created with ID: ${THEME_ID}"
  
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
