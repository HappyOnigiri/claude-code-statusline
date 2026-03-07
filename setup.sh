#!/bin/bash
set -e

SCRIPT_URL="https://raw.githubusercontent.com/HappyOnigiri/claude-code-statusline/main/statusline-command.sh"
CLAUDE_DIR="$HOME/.claude"
DEST_SCRIPT="$CLAUDE_DIR/statusline-command.sh"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

STATUS_LINE_ENTRY='{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}'

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  echo "Install it with: brew install jq" >&2
  exit 1
fi

# Ensure ~/.claude/ exists
mkdir -p "$CLAUDE_DIR"

# Download statusline-command.sh
echo "Downloading statusline-command.sh..."
curl -fsSL "$SCRIPT_URL" -o "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"
echo "Saved to $DEST_SCRIPT"

# Merge statusLine into settings.json
if [ -f "$SETTINGS_FILE" ]; then
  original=$(cat "$SETTINGS_FILE")
else
  original="{}"
fi

updated=$(echo "$original" | jq ". * $STATUS_LINE_ENTRY")

# Show diff and confirm
echo ""
echo "The following change will be made to $SETTINGS_FILE:"
echo ""
diff <(echo "$original" | jq .) <(echo "$updated" | jq .) || true
echo ""

# Read from /dev/tty to support `curl | bash` piped execution
read -r -p "Apply changes? [y/N] " answer </dev/tty
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo "$updated" | jq . > "$SETTINGS_FILE"
echo "Done. $SETTINGS_FILE updated."
