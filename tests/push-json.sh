#!/bin/bash
# Checks that `theme push --json` output is read from both CLI 4 (one-line
# `{"theme":{...}}`) and CLI 5 (event lines, then a multi-line result).
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PROGRESS='{"type":"progress","timestamp":"2026-10-27T13:21:12Z","status":"started","operation":"290fca23","message":"Uploading files to remote theme [0%]"}
{"type":"diagnostic","timestamp":"2026-10-27T13:21:13Z","level":"info","message":"Theme created"}
{"type":"progress","timestamp":"2026-10-27T13:21:20Z","status":"completed","operation":"290fca23","message":"Uploading files to remote theme [100%]"}'

CLI4='{"theme":{"id":111,"name":"PR #1","role":"unpublished","shop":"example.myshopify.com","editor_url":"e","preview_url":"p"}}'
CLI4_ERRORS='{"theme":{"id":111,"name":"PR #1","role":"unpublished","errors":{"sections/a.liquid":["Liquid syntax error"]}}}'
CLI5="${PROGRESS}
{
  \"status\": \"success\",
  \"changed\": true,
  \"theme\": {
    \"id\": \"222\",
    \"name\": \"PR #1\",
    \"role\": \"unpublished\",
    \"storeDomain\": \"example.myshopify.com\",
    \"previewUrl\": \"https://example.myshopify.com?preview_theme_id=222\",
    \"editorUrl\": \"https://example.myshopify.com/admin/themes/222/editor\"
  },
  \"issues\": []
}"
CLI5_PARTIAL="${PROGRESS}
{
  \"status\": \"partial\",
  \"changed\": true,
  \"theme\": {
    \"id\": \"333\",
    \"name\": \"PR #1\",
    \"role\": \"unpublished\",
    \"storeDomain\": \"example.myshopify.com\",
    \"previewUrl\": null,
    \"editorUrl\": null
  },
  \"issues\": [
    {
      \"filePath\": \"templates/page.json\",
      \"message\": \"Invalid block type\"
    }
  ]
}"
CLI5_ABORT="${PROGRESS}
{
  \"error\": {
    \"type\": \"abort\",
    \"message\": \"Theme limit reached\"
  }
}"

source "$ROOT/scripts/lib/common.sh"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got: $2, want: $3)"; fail=1; fi; }
field() { extract_push_json "$1" | extract_json_value "" "$2"; }

check "cli4 id" "$(field "$CLI4" theme_id)" "111"
check "cli4 errors" "$(field "$CLI4_ERRORS" error_count)" "1"
check "cli5 id" "$(field "$CLI5" theme_id)" "222"
check "cli5 no errors" "$(field "$CLI5" error_count)" "0"
check "cli5 unindented id" "$(field "$(printf '%s' "$CLI5" | sed 's/^ *//')" theme_id)" "222"
check "cli5 partial id" "$(field "$CLI5_PARTIAL" theme_id)" "333"
check "cli5 partial errors" "$(field "$CLI5_PARTIAL" error_count)" "1"
check "cli5 partial message" "$(field "$CLI5_PARTIAL" format_errors)" "• templates/page.json: Invalid block type"
check "cli5 abort" "$(extract_push_json "$CLI5_ABORT")" ""
check "plain text" "$(extract_push_json "Error: something went wrong")" ""

# create_theme_with_retry against a fake CLI that prints the CLI 5 output.
mkdir -p "$WORK/bin"
printf '%s\n' '#!/bin/bash' 'cat "$(dirname "$0")/output"' > "$WORK/bin/shopify"
printf '%s' "$CLI5" > "$WORK/bin/output"
chmod +x "$WORK/bin/shopify"
export PATH="$WORK/bin:$PATH"
export THEME_ROOT="$WORK"

source "$ROOT/scripts/lib/theme.sh"
status=0
create_theme_with_retry "PR #1" > /dev/null || status=$?
check "cli5 create status" "$status" "0"
check "cli5 create id" "$CREATED_THEME_ID" "222"

exit $fail
