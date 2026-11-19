#!/bin/bash
# Checks deploy and cleanup against a fake `shopify` CLI emitting the CLI 5.x JSON shapes:
# `theme push --json` prints NDJSON progress lines then a pretty-printed result,
# `theme list --json` prints {"themes":[...]}. The legacy 3.x shapes must keep working.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fake CLI: push prints $FAKE_PUSH_OUTPUT, list prints $FAKE_LIST_OUTPUT, delete records the ID.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/shopify" <<'EOF'
#!/bin/bash
case "$2" in
  push) cat "$FAKE_PUSH_OUTPUT"; exit "${FAKE_PUSH_STATUS:-0}" ;;
  list) cat "$FAKE_LIST_OUTPUT" ;;
  delete)
    while [ $# -gt 0 ]; do case "$1" in -t|--theme) echo "$2" >> "$FAKE_DELETED";; esac; shift; done
    echo "╭─ success ───╮"; echo "│ The theme was deleted. │"; echo "╰─────────────╯" ;;
esac
EOF
# Fake curl: GitHub returns no PR comments.
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "\n%{http_code}" ] && { printf '[]\n200'; exit 0; }; done
echo '[]'
EOF
chmod +x "$WORK/bin/shopify" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export FAKE_DELETED="$WORK/deleted" FAKE_PUSH_OUTPUT="$WORK/push.out" FAKE_LIST_OUTPUT="$WORK/list.out"
export THEME_ROOT="$WORK" SHOPIFY_FLAG_STORE="test.myshopify.com" GITHUB_TOKEN=x SHOPIFY_CLI_THEME_TOKEN=x
export GITHUB_REPOSITORY="org/repo" PR_NUMBER=1

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected: $3, got: $2)"; fail=1; fi; }

progress() {
  echo '{"type":"progress","timestamp":"2026-11-18T12:49:34Z","status":"started","operation":"614268e0","message":"Uploading files to remote theme [0%]"}'
  echo '{"type":"progress","timestamp":"2026-11-18T12:49:40Z","status":"updated","operation":"614268e0","message":"Uploading files to remote theme [21%]"}'
  echo '{"type":"progress","timestamp":"2026-11-18T12:49:50Z","status":"completed","operation":"614268e0","message":"Theme upload complete","current":1,"total":1}'
}

source "$ROOT/scripts/lib/theme.sh"

# 1. CLI 5.x create: progress lines + pretty-printed success (output from pergolux#628).
{ progress; cat <<'EOF'
{
  "status": "success",
  "changed": true,
  "theme": {
    "id": "194369159543",
    "name": "[LUX-892] Let the contact card cover the button an",
    "role": "unpublished",
    "storeDomain": "pergolux-tyskland.myshopify.com",
    "previewUrl": "https://pergolux-tyskland.myshopify.com?preview_theme_id=194369159543",
    "editorUrl": "https://pergolux-tyskland.myshopify.com/admin/themes/194369159543/editor"
  },
  "issues": []
}
EOF
} > "$WORK/push.out"
rc=0; create_theme_with_retry "[LUX-892] Let the contact card cover the button an" > /dev/null || rc=$?
check "5.x create succeeds" "$rc" 0
check "5.x create theme ID" "$CREATED_THEME_ID" 194369159543
check "5.x create no errors" "$THEME_ERRORS" ""

# 2. Theme name containing "limit" is not mistaken for a theme-limit error.
sed 's/Let the contact card cover the button an/Raise the cart limit/' "$WORK/push.out" > "$WORK/push.tmp" && mv "$WORK/push.tmp" "$WORK/push.out"
rc=0; create_theme_with_retry "[LUX-1] Raise the cart limit" > /dev/null || rc=$?
check "5.x create with 'limit' in name succeeds" "$rc" 0
check "nothing deleted for 'limit' in name" "$(cat "$FAKE_DELETED" 2>/dev/null)" ""

# 3. CLI 5.x partial push: issues are errors, the new theme is removed, the step fails.
{ progress; cat <<'EOF'
{
  "status": "partial",
  "changed": true,
  "theme": { "id": "555", "name": "x", "role": "unpublished", "storeDomain": "s", "previewUrl": null, "editorUrl": null },
  "issues": [ { "filePath": "/repo/sections/header.liquid", "message": "Liquid syntax error" } ]
}
EOF
} > "$WORK/push.out"
rc=0; create_theme_with_retry "x" > /dev/null || rc=$?
check "5.x partial create fails" "$rc" 1
check "5.x partial theme deleted" "$(cat "$FAKE_DELETED")" 555
check "5.x partial errors reported" "$(printf '%s' "$THEME_ERRORS" | grep -c 'Liquid syntax error')" 1
rm -f "$FAKE_DELETED"

rc=0; upload_theme 555 false > /dev/null || rc=$?
check "5.x partial update fails" "$rc" 1

# 4. Legacy 3.x single-line result still parses.
echo '{"theme":{"id":777,"name":"x","role":"unpublished","shop":"s","editor_url":"e","preview_url":"p"}}' > "$WORK/push.out"
rc=0; create_theme_with_retry "x" > /dev/null || rc=$?
check "3.x create succeeds" "$rc" 0
check "3.x create theme ID" "$CREATED_THEME_ID" 777

# 5. Cleanup with no marker comment finds the unpublished theme by name in a 5.x list,
#    and never picks a live or development theme that happens to share the name.
cat > "$WORK/list.out" <<'EOF'
{"themes":[
  {"id":"100","name":"[LUX-887] Contact popup shine and iMessage-style b","role":"live","processing":false},
  {"id":"101","name":"[LUX-887] Contact popup shine and iMessage-style b","role":"development","processing":false},
  {"id":"194272690551","name":"[LUX-887] Contact popup shine and iMessage-style b","role":"unpublished","processing":false}
]}
EOF
out=$(PR_TITLE="[LUX-887] Contact popup shine and iMessage-style bubble" bash "$ROOT/scripts/cleanup.sh" 2>&1)
check "cleanup deletes only the unpublished match" "$(cat "$FAKE_DELETED" 2>/dev/null)" 194272690551
rm -f "$FAKE_DELETED"

# 6. Same with the legacy bare-array list.
echo '[{"id":42,"name":"Legacy PR","role":"unpublished"}]' > "$WORK/list.out"
PR_TITLE="Legacy PR" bash "$ROOT/scripts/cleanup.sh" > /dev/null 2>&1
check "cleanup with 3.x list" "$(cat "$FAKE_DELETED" 2>/dev/null)" 42

# 7. Deploy's name lookup never returns a live theme (it would push PR code onto it).
echo '{"themes":[{"id":"100","name":"Same name","role":"live","processing":false}]}' > "$WORK/list.out"
rc=0; check_theme_exists_by_name "Same name" > /dev/null 2>&1 || rc=$?
check "deploy name lookup skips live theme" "$rc" 1

exit $fail
