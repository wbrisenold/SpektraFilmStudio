#!/usr/bin/env bash
set -euo pipefail

HOOK=".git/hooks/pre-commit"

# Remove any prior hook verbatim, including the repomix-only version.
rm -f "$HOOK"
rm -f ".git/hooks/pre-commit.repomix.bak"

cat >"$HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git-format-staged --formatter "swiftformat stdin --stdin-path '{}'" "*.swift"
EOF
chmod +x "$HOOK"
echo "installed $HOOK"
