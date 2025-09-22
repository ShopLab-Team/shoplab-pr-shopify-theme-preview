#!/bin/bash
# Common utility functions for Shopify theme deployment scripts

# Function to strip ANSI color codes
strip_ansi_codes() {
  local input="$1"
  # Remove ANSI escape codes
  printf '%s' "$input" | sed -E 's/\x1b\[[0-9;]*[mGKH]//g'
}

# Function to clean error messages for Slack
clean_for_slack() {
  local input="$1"
  # Remove box drawing characters and ANSI escape codes
  # Extract meaningful content from Shopify CLI output
  local cleaned
  cleaned=$(printf '%s' "$input" | \
    awk '{
      # Remove box drawing characters
      gsub(/[╭╮╰╯─│║┃┊┋╎╏]/, " ");
      # Remove ANSI escape codes
      gsub(/\x1b\[[0-9;]*[mGKH]/, "");
      # Trim leading and trailing whitespace
      gsub(/^[ \t]+|[ \t]+$/, "");
      # Collapse multiple spaces
      gsub(/  +/, " ");
      # Replace standalone "error" with "Error:"
      if ($0 == "error") $0 = "Error:";
      # Print non-empty lines
      if (length($0) > 0) print $0
    }')
  
  printf '%s' "$cleaned"
}

# Helper function: Parse JSON using Node.js instead of jq
parse_json() {
  local json_input="$1"
  local json_path="$2"
  local default_value="${3:-}"
  
  echo "$json_input" | node -e "
    const data = require('fs').readFileSync(0, 'utf8');
    if (!data.trim()) {
      console.log('$default_value');
      process.exit(0);
    }
    try {
      const obj = JSON.parse(data);
      const path = '$json_path'.split('.');
      let result = obj;
      for (const key of path) {
        if (key && result != null) {
          result = result[key];
        }
      }
      console.log(result != null ? result : '$default_value');
    } catch (error) {
      console.log('$default_value');
    }
  " 2>/dev/null || echo "$default_value"
}

# Helper function: Safe JSON extraction with specific queries
extract_json_value() {
  local json_input="$1"
  local extraction_type="$2"
  
  # If json_input is empty, read from stdin
  if [ -z "$json_input" ]; then
    json_input=$(cat)
  fi
  
  case "$extraction_type" in
    "theme_id")
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log((o.theme?.id)||'');}catch(e){console.log('');}"
      ;;
    "error_count")
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log((o.theme?.errors)?Object.keys(o.theme.errors).length:0);}catch(e){console.log('0');}"
      ;;
    "warning")
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(o.theme?.warning||'');}catch(e){console.log('');}"
      ;;
    "format_errors")
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));const e=o.theme?.errors||{};const l=Object.entries(e).map(([k,v])=>'• '+k+': '+(Array.isArray(v)?v.join(', '):v));console.log(l.join('\\n'));}catch(e){console.log('');}"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Helper function: extract the most recent theme marker from PR comments
extract_latest_theme_marker() {
  local input_json
  input_json=$(cat)
  
  echo "$input_json" | node -e "
    const data = require('fs').readFileSync(0, 'utf8');
    try {
      const comments = JSON.parse(data);
      const markers = [];
      
      comments.forEach(comment => {
        const matches = comment.body.match(/<!-- SHOPIFY_THEME_ID: (\\d+) -->/g);
        if (matches) {
          matches.forEach(match => {
            const id = match.match(/\\d+/)[0];
            markers.push({
              id: id,
              created_at: comment.created_at
            });
          });
        }
      });
      
      if (markers.length === 0) {
        console.log('');
        return;
      }
      
      // Sort by creation date (most recent first)
      markers.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
      
      console.error('Found ' + markers.length + ' theme markers in comments');
      console.error('Selected theme ID: ' + markers[0].id + ' (most recent)');
      
      console.log(markers[0].id);
    } catch (error) {
      console.error('Error parsing comments:', error.message);
      console.log('');
    }
  " 2>&1 | {
    # Capture both stdout and stderr
    local output
    local debug_output=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^Found\ |^Selected\ |^Error\  ]]; then
        debug_output="${debug_output}${line}\n"
      else
        output="$line"
      fi
    done
    [ -n "$debug_output" ] && echo -e "$debug_output" >&2
    echo "$output"
  }
}

# Export functions for use in other scripts
export -f strip_ansi_codes
export -f clean_for_slack
export -f parse_json
export -f extract_json_value
export -f extract_latest_theme_marker
