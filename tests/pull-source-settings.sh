#!/bin/bash
# Checks pull_source_settings against a fake `shopify` CLI:
# source JSON wins, repo blocks are kept, missing (e.g. AI-generated) blocks are added.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fake CLI: `shopify theme pull ... --path <dir> ...` writes the "source theme" files into <dir>.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/shopify" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = "--path" ] && dir=$2; shift; done
mkdir -p "$dir/templates" "$dir/blocks"
echo '{"source":true}' > "$dir/templates/index.json"
echo 'source version' > "$dir/blocks/_shared.liquid"
echo 'ai block' > "$dir/blocks/ai_gen_block_abc.liquid"
EOF
chmod +x "$WORK/bin/shopify"
export PATH="$WORK/bin:$PATH"

# Checkout: a block only the PR has, a block the PR changed, a template only the PR has.
export THEME_ROOT="$WORK/theme"
mkdir -p "$THEME_ROOT/templates" "$THEME_ROOT/blocks"
echo '{"source":false}' > "$THEME_ROOT/templates/index.json"
echo 'pr version' > "$THEME_ROOT/blocks/_shared.liquid"
echo 'new in pr' > "$THEME_ROOT/blocks/_recovery-proof.liquid"
echo '{}' > "$THEME_ROOT/templates/product.new.json"

source "$ROOT/scripts/lib/theme.sh"
pull_source_settings "--theme 123" "" > /dev/null

fail=0
check() { if [ "$(cat "$THEME_ROOT/$1" 2>/dev/null)" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (got: $(cat "$THEME_ROOT/$1" 2>/dev/null || echo missing))"; fail=1; fi; }
check templates/index.json '{"source":true}'
check templates/product.new.json '{}'
check blocks/_shared.liquid 'pr version'
check blocks/_recovery-proof.liquid 'new in pr'
check blocks/ai_gen_block_abc.liquid 'ai block'
exit $fail
