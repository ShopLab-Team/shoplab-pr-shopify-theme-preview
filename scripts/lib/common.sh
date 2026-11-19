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

# Helper function: extract the result object from `shopify theme push --json` output (stdin).
# CLI 3.x prints one line: {"theme":{...}}. CLI 5.x prints NDJSON {"type":"progress",...} lines,
# then a pretty-printed {"status":...,"theme":{...},"issues":[...]}. Text from stderr can be mixed in.
# Prints the last JSON object that isn't a progress event, compacted to one line, or nothing.
extract_cli_result() {
  node -e '
    const out = require("fs").readFileSync(0, "utf8");
    let result = "";
    for (let i = 0; i < out.length; i++) {
      if (out[i] !== "{") continue;
      // Find the matching closing brace, skipping braces inside strings
      let depth = 0, inString = false, end = -1;
      for (let j = i; j < out.length; j++) {
        const c = out[j];
        if (inString) {
          if (c === "\\") j++;
          else if (c === "\"") inString = false;
        } else if (c === "\"") inString = true;
        else if (c === "{") depth++;
        else if (c === "}" && --depth === 0) { end = j; break; }
      }
      if (end === -1) continue;
      try {
        const obj = JSON.parse(out.slice(i, end + 1));
        if (obj && obj.type !== "progress") result = JSON.stringify(obj);
        i = end;
      } catch (e) {
        // Not JSON (e.g. Liquid in an error message) - keep scanning
      }
    }
    process.stdout.write(result);
  ' 2>/dev/null || true
}

# Helper function: Safe JSON extraction with specific queries
# Accepts both the CLI 3.x push result ({theme:{id,errors,warning}}) and
# the CLI 5.x one ({status,theme:{id},issues:[{filePath,message}]})
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
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(Array.isArray(o.issues)?o.issues.length:(o.theme?.errors)?Object.keys(o.theme.errors).length:0);}catch(e){console.log('0');}"
      ;;
    "warning")
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(o.theme?.warning||'');}catch(e){console.log('');}"
      ;;
    "format_errors")
      echo "$json_input" | node -e "try{const o=JSON.parse(require('fs').readFileSync(0,'utf8'));const e=o.theme?.errors||{};const l=Array.isArray(o.issues)?o.issues.map(i=>'• '+i.filePath+': '+i.message):Object.entries(e).map(([k,v])=>'• '+k+': '+(Array.isArray(v)?v.join(', '):v));console.log(l.join('\\n'));}catch(e){console.log('');}"
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
  
  # Use a simpler approach without complex pipes
  local result
  result=$(echo "$input_json" | node -e "
    const data = require('fs').readFileSync(0, 'utf8');
    try {
      const comments = JSON.parse(data);
      if (!Array.isArray(comments) || comments.length === 0) {
        console.log('');
        process.exit(0);
      }
      
      const markers = [];
      
      // Look for theme ID markers in each comment
      comments.forEach(comment => {
        if (!comment.body) return;
        
        // Look for the theme ID marker pattern
        const regex = /<!-- SHOPIFY_THEME_ID: (\\d+) -->/g;
        let match;
        while ((match = regex.exec(comment.body)) !== null) {
          markers.push({
            id: match[1],
            created_at: comment.created_at
          });
        }
      });
      
      if (markers.length === 0) {
        console.log('');
        process.exit(0);
      }
      
      // Sort by creation date (most recent first)
      markers.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
      
      // Output only the most recent theme ID
      console.log(markers[0].id);
    } catch (error) {
      // Silent error - just return empty
      console.log('');
    }
  " 2>/dev/null)
  
  echo "$result"
}

# Export functions for use in other scripts
export -f strip_ansi_codes
export -f clean_for_slack
export -f parse_json
export -f extract_json_value
export -f extract_cli_result
export -f extract_latest_theme_marker
