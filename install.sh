#!/usr/bin/env bash
# Install the sky agent toolkit into a project as a git submodule.
#
# This script:
#   1. Adds sky as a git submodule at sky/ (if not already present)
#   2. Symlinks CLAUDE.md, AGENTS.md, and .claude/ into the project root
#   3. Adds sky/scripts to PATH via .envrc
#
# Usage (from your project root):
#   /path/to/sky/install.sh                    # if sky is already cloned locally
#   curl -sSL https://raw.githubusercontent.com/radiospiel/sky/main/install.sh | bash
#
# Environment variables:
#   SKY_REPO_URL   Git URL for the sky repo
#                  (default: https://github.com/radiospiel/sky.git)
#   SKY_REV        Branch/tag/commit to check out (default: main)

set -euo pipefail

SKY_REPO_URL="${SKY_REPO_URL:-https://github.com/radiospiel/sky.git}"
SKY_REV="${SKY_REV:-main}"

# ── Helpers ──────────────────────────────────────────────────────────────────

symlink_force() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    echo "[sky] backing up existing $dst → $dst.bak" >&2
    mv "$dst" "$dst.bak"
  fi
  ln -s "$src" "$dst"
  echo "[sky] linked $dst → $src"
}

# ── Ensure we're in a git repo root ──────────────────────────────────────────

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Error: not in a git repository. Run this from your project root." >&2
  exit 1
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "$PROJECT_ROOT"

# ── Add sky as a submodule ───────────────────────────────────────────────────

if [ -d sky/.git ] || git submodule status sky/ >/dev/null 2>&1; then
  echo "[sky] submodule already exists at sky/ — updating..."
  git submodule update --init --remote sky/ 2>/dev/null || true
else
  echo "[sky] adding submodule from $SKY_REPO_URL..."
  git submodule add "$SKY_REPO_URL" sky/
fi

cd sky
git fetch origin "$SKY_REV" 2>/dev/null || true
git checkout "origin/$SKY_REV" 2>/dev/null || git checkout "$SKY_REV" 2>/dev/null || true
cd "$PROJECT_ROOT"

# ── Symlink config files ─────────────────────────────────────────────────────

# CLAUDE.md
if [ ! -e CLAUDE.md ] || [ -L CLAUDE.md ]; then
  symlink_force "sky/CLAUDE.md" "CLAUDE.md"
else
  echo "[sky] CLAUDE.md exists and is not a symlink — skipping (remove it first to adopt sky's version)"
fi

# AGENTS.md
if [ ! -e AGENTS.md ] || [ -L AGENTS.md ]; then
  symlink_force "sky/AGENTS.md" "AGENTS.md"
else
  echo "[sky] AGENTS.md exists and is not a symlink — skipping (remove it first to adopt sky's version)"
fi

# .claude/ directory — merge individual files rather than replacing wholesale
mkdir -p .claude/hooks agents/skills

# .claude/settings.json
if [ ! -e .claude/settings.json ] || [ -L .claude/settings.json ]; then
  symlink_force "../sky/.claude/settings.json" ".claude/settings.json"
else
  echo "[sky] .claude/settings.json exists and is not a symlink — skipping"
fi

# .claude/settings.local.json
if [ ! -e .claude/settings.local.json ]; then
  cp sky/.claude/settings.local.json.example .claude/settings.local.json
  echo "[sky] created .claude/settings.local.json from example — review and customize it"
else
  echo "[sky] .claude/settings.local.json already exists — skipping"
fi

# .claude/hooks/session-start.sh
if [ ! -e .claude/hooks/session-start.sh ] || [ -L .claude/hooks/session-start.sh ]; then
  mkdir -p .claude/hooks
  symlink_force "../../sky/.claude/hooks/session-start.sh" ".claude/hooks/session-start.sh"
else
  echo "[sky] .claude/hooks/session-start.sh exists and is not a symlink — skipping"
fi

# agents/skills/auto-fix/
if [ ! -e agents/skills/auto-fix ] || [ -L agents/skills/auto-fix ]; then
  mkdir -p agents/skills
  symlink_force "../../sky/agents/skills/auto-fix" "agents/skills/auto-fix"
else
  echo "[sky] agents/skills/auto-fix exists and is not a symlink — skipping"
fi

# ── .envrc ───────────────────────────────────────────────────────────────────

if ! grep -q 'PATH_add sky/scripts' .envrc 2>/dev/null; then
  if [ ! -f .envrc ]; then
    echo 'PATH_add sky/scripts' > .envrc
  else
    echo 'PATH_add sky/scripts' >> .envrc
  fi
  echo "[sky] added PATH_add sky/scripts to .envrc"
else
  echo "[sky] .envrc already references sky/scripts"
fi

# ── .gitignore ───────────────────────────────────────────────────────────────

if ! grep -q '^.claude/settings.local.json$' .gitignore 2>/dev/null; then
  echo '' >> .gitignore
  echo '# sky: settings.local.json contains per-user permissions (not tracked)' >> .gitignore
  echo '.claude/settings.local.json' >> .gitignore
  echo "[sky] added .claude/settings.local.json to .gitignore"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Sky toolkit installed successfully."
echo ""
echo "Next steps:"
echo "  1. Review and customize .claude/settings.local.json"
echo "  2. direnv allow   (if using direnv, to load sky/scripts onto PATH)"
echo "  3. git add sky/ CLAUDE.md AGENTS.md .claude/ .envrc .gitignore"
echo "  4. git commit -m 'chore: add sky agent toolkit submodule'"
echo ""
echo "To update sky later:"
echo "  cd sky && git pull origin main && cd .. && git add sky && git commit -m 'chore: update sky'"
