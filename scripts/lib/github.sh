#!/bin/bash
# GitHub API functions for Shopify theme deployment scripts

# Source common utilities if not already loaded
[[ -z "${COMMON_UTILS_LOADED}" ]] && source "${BASH_SOURCE%/*}/common.sh" && COMMON_UTILS_LOADED=1

# Function to make GitHub API calls with retry logic
github_api() {
  local endpoint="$1"
  local method="${2:-GET}"
  local data="${3:-}"
  local max_retries=3
  local retry_count=0
  local wait_time=1
  
  while [ $retry_count -lt $max_retries ]; do
    local response
    local http_code
    
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
      response=$(curl -s -w "\n%{http_code}" \
        --connect-timeout 10 --max-time 30 \
        -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "https://api.github.com${endpoint}" 2>&1)
    else
      response=$(curl -s -w "\n%{http_code}" \
        --connect-timeout 10 --max-time 30 \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com${endpoint}" 2>&1)
    fi
    
    # Extract HTTP status code (last line)
    http_code=$(echo "$response" | tail -1)
    # Remove status code from response
    response=$(echo "$response" | sed '$d')
    
    # Check for rate limit (403 or 429)
    if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
      echo "⚠️ GitHub API rate limit hit. Waiting 60 seconds..." >&2
      sleep 60
      retry_count=$((retry_count + 1))
      continue
    fi
    
    # Check for success (2xx)
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      echo "$response"
      return 0
    fi
    
    # For other errors, retry with exponential backoff
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      echo "⚠️ GitHub API call failed (HTTP $http_code). Retrying in ${wait_time}s..." >&2
      sleep $wait_time
      wait_time=$((wait_time * 2))
    fi
  done
  
  echo "❌ GitHub API call failed after $max_retries attempts" >&2
  return 1
}

# Function to post comment on PR
post_pr_comment() {
  local pr_number="$1"
  local comment_body="$2"
  local repo="${GITHUB_REPOSITORY}"
  
  local json_body
  json_body=$(node -e "
    const body = process.argv[1];
    console.log(JSON.stringify({ body: body }));
  " -- "$comment_body")
  
  github_api "/repos/${repo}/issues/${pr_number}/comments" "POST" "$json_body"
}

# Function to fetch PR comments
fetch_pr_comments() {
  local pr_number="$1"
  local repo="${GITHUB_REPOSITORY}"
  
  github_api "/repos/${repo}/issues/${pr_number}/comments"
}

# Function to check if PR has a specific label
pr_has_label() {
  local pr_number="$1"
  local label_name="$2"
  local repo="${GITHUB_REPOSITORY}"
  
  local labels
  labels=$(github_api "/repos/${repo}/issues/${pr_number}/labels")
  
  echo "$labels" | node -e "
    const data = require('fs').readFileSync(0, 'utf8');
    try {
      const labels = JSON.parse(data);
      const hasLabel = labels.some(l => l.name === process.argv[1]);
      console.log(hasLabel ? 'true' : 'false');
    } catch (e) {
      console.log('false');
    }
  " -- "$label_name"
}

# Export functions for use in other scripts
export -f github_api
export -f post_pr_comment
export -f fetch_pr_comments
export -f pr_has_label
