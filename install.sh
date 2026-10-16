#!/usr/bin/env bash
# install.sh - run from the cloned repo:
#   ./install.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed. Install it first, e.g.:" >&2
  echo "  sudo apt install jq     # Debian/Ubuntu" >&2
  echo "  sudo dnf install jq     # Fedora" >&2
  echo "  sudo pacman -S jq       # Arch" >&2
  exit 1
fi

dest="$HOME/.claude-cli.sh"
cp "$here/claude-cli.sh" "$dest"
echo "Installed $dest"

cfg="$HOME/.claude-accounts.json"
if [ ! -f "$cfg" ]; then
  # Don't copy claude-accounts.example.json: its paths are Windows-style.
  jq -n --arg work "$HOME/.claude-work" \
    '{default: "personal", profiles: {personal: "", work: $work}, byPath: {}, byOrg: {}}' > "$cfg"
  echo "Created $cfg  (edit it: cca edit)"
else
  echo "$cfg already exists - left as is"
fi

rc="$HOME/.bashrc"
touch "$rc"
if grep -qF '.claude-cli.sh' "$rc"; then
  echo "Already wired: $rc"
else
  cat >> "$rc" <<'EOF'

# Claude account-aware launcher (claude-account-switcher)
[ -f "$HOME/.claude-cli.sh" ] && . "$HOME/.claude-cli.sh"
EOF
  echo "Wired: $rc"
fi

echo
echo "Done. Open a NEW terminal (or run:  source ~/.bashrc ) to activate."
echo "Then run:  cca edit   to set your profiles + folder/org rules."
