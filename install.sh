#!/bin/bash
# Compound Product Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#    or: ./install.sh [target_project_path]

set -e

REPO_URL="https://github.com/snarktank/compound-product.git"

# Detect if running via curl pipe (no BASH_SOURCE or it points to stdin)
if [ -z "${BASH_SOURCE[0]}" ] || [ "${BASH_SOURCE[0]}" = "bash" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
  # Running via curl | bash - clone to temp dir
  TEMP_DIR="$(mktemp -d)"
  trap "rm -rf '$TEMP_DIR'" EXIT
  echo "Cloning compound-product..."
  git clone --quiet "$REPO_URL" "$TEMP_DIR/compound-product"
  SCRIPT_DIR="$TEMP_DIR/compound-product"
else
  # Running locally - but verify this is actually a compound-product repo
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if this looks like a compound-product repo (has our key files)
  if [ ! -f "$SCRIPT_DIR/scripts/auto-compound.sh" ] || [ ! -f "$SCRIPT_DIR/config.example.json" ]; then
    # Not a compound-product repo - clone fresh
    TEMP_DIR="$(mktemp -d)"
    trap "rm -rf '$TEMP_DIR'" EXIT
    echo "Cloning compound-product..."
    git clone --quiet "$REPO_URL" "$TEMP_DIR/compound-product"
    SCRIPT_DIR="$TEMP_DIR/compound-product"
  fi
fi

TARGET_DIR="${1:-$(pwd)}"

# Resolve to absolute path
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || {
  echo "Error: Target directory does not exist: $1"
  exit 1
}

echo "Installing Compound Product to: $TARGET_DIR"

# Create directories
mkdir -p "$TARGET_DIR/scripts/compound"
mkdir -p "$TARGET_DIR/reports"

# Copy scripts
echo "Copying scripts..."
cp "$SCRIPT_DIR/scripts/"* "$TARGET_DIR/scripts/compound/"
chmod +x "$TARGET_DIR/scripts/compound/"*.sh

# Copy config if it doesn't exist
if [ ! -f "$TARGET_DIR/compound.config.json" ]; then
  echo "Creating config file..."
  cp "$SCRIPT_DIR/config.example.json" "$TARGET_DIR/compound.config.json"
else
  echo "Config file already exists, skipping..."
fi

# Skills installation locations for different agents
# Agent Skills is an emerging open standard: https://agentskills.io
# Note: Using simple variables instead of associative arrays for bash 3.x compatibility (macOS)
SKILL_DIR_AMP="$HOME/.config/amp/skills"
SKILL_DIR_CLAUDE="$HOME/.claude/skills"
SKILL_DIR_CODEX="$HOME/.codex/skills"
SKILL_DIR_COPILOT="$HOME/.copilot/skills"

install_skills() {
  local name="$1"
  local dir="$2"
  
  if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
    echo "Installing skills for $name to $dir"
    cp -r "$SCRIPT_DIR/skills/prd" "$dir/"
    cp -r "$SCRIPT_DIR/skills/tasks" "$dir/"
  fi
}

INSTALLED_ANY=false

# Install for Amp CLI
if command -v amp >/dev/null 2>&1; then
  install_skills "Amp" "$SKILL_DIR_AMP"
  INSTALLED_ANY=true
fi

# Install for Claude Code
if command -v claude >/dev/null 2>&1; then
  install_skills "Claude Code" "$SKILL_DIR_CLAUDE"
  INSTALLED_ANY=true
fi

# Install for Codex CLI
if command -v codex >/dev/null 2>&1; then
  install_skills "Codex" "$SKILL_DIR_CODEX"
  INSTALLED_ANY=true
fi

# Check for VS Code / Copilot (install to user skills dir)
if command -v code >/dev/null 2>&1; then
  install_skills "VS Code Copilot" "$SKILL_DIR_COPILOT"
  INSTALLED_ANY=true
fi

# If no agents detected, show manual instructions
if [ "$INSTALLED_ANY" = false ]; then
  echo ""
  echo "No supported AI coding agents detected."
  echo ""
  echo "Skills can be installed manually based on your agent:"
  echo ""
  echo "  Amp CLI:        cp -r skills/* ~/.config/amp/skills/"
  echo "  Claude Code:    cp -r skills/* ~/.claude/skills/"
  echo "  Codex CLI:      cp -r skills/* ~/.codex/skills/"
  echo "  VS Code/Copilot: cp -r skills/* ~/.copilot/skills/"
  echo "  Cursor:         cp -r skills/* .cursor/rules/  (project-level)"
  echo ""
  echo "Or install to your project's .github/skills/ directory for the"
  echo "Agent Skills standard (works with multiple agents):"
  echo "  cp -r skills/* .github/skills/"
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "Next steps:"
echo "1. Edit compound.config.json to configure for your project"
echo "2. Add a report to ./reports/ (any markdown file)"
echo "3. Run: vercel env pull  (or set ANTHROPIC_API_KEY)"
echo "4. Run: ./scripts/compound/auto-compound.sh --dry-run"
echo ""
echo "See README.md for full documentation."
