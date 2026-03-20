#!/usr/bin/env bash
set -e

# SpendControl MCP Server Installer
# Usage: curl -sL HOST/install.sh | bash -s -- VAULT_ADDRESS AGENT_PRIVATE_KEY [RPC_URL]

VAULT_ADDRESS="${1}"
AGENT_KEY="${2}"
RPC_URL="${3:-https://sepolia.base.org}"
INSTALL_DIR="$HOME/.spendcontrol"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
# Where to download the MCP server from (same host as install.sh)
HOST="${SPENDCONTROL_HOST:-https://spendcontrol.xyz}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}SpendControl${NC} — MCP Server Installer"
echo ""

# Validate inputs
if [ -z "$VAULT_ADDRESS" ] || [ -z "$AGENT_KEY" ]; then
  echo -e "${RED}Usage: curl -sL .../install.sh | bash -s -- VAULT_ADDRESS AGENT_PRIVATE_KEY [RPC_URL]${NC}"
  echo ""
  echo "  VAULT_ADDRESS      Your vault contract address (from dashboard)"
  echo "  AGENT_PRIVATE_KEY  Private key for the agent wallet"
  echo "  RPC_URL            RPC endpoint (default: https://sepolia.base.org)"
  exit 1
fi

# Check Node.js
if ! command -v node &>/dev/null; then
  echo -e "${RED}Error: Node.js is required. Install from https://nodejs.org${NC}"
  exit 1
fi

NODE_VERSION=$(node -v | cut -d'.' -f1 | tr -d 'v')
if [ "$NODE_VERSION" -lt 18 ]; then
  echo -e "${RED}Error: Node.js 18+ required (you have $(node -v))${NC}"
  exit 1
fi

echo -e "${DIM}  Vault:   ${VAULT_ADDRESS}${NC}"
echo -e "${DIM}  Network: ${RPC_URL}${NC}"
echo ""

# Step 1: Download MCP server
echo -e "  ${CYAN}[1/3]${NC} Installing MCP server..."
mkdir -p "$INSTALL_DIR"

# Download server files from host
curl -sL "${HOST}/mcp/package.json" -o "$INSTALL_DIR/package.json"
curl -sL "${HOST}/mcp/index.js" -o "$INSTALL_DIR/index.js"

# Install deps
cd "$INSTALL_DIR" && npm install --silent 2>/dev/null
echo -e "  ${CYAN}[1/3]${NC} Installed to ${DIM}~/.spendcontrol/${NC}"

# Step 2: Configure Claude Code settings
echo -e "  ${CYAN}[2/3]${NC} Configuring Claude Code..."
mkdir -p "$HOME/.claude"

# Use node to safely merge JSON settings
node -e "
const fs = require('fs');
const path = '$CLAUDE_SETTINGS';
let settings = {};
try { settings = JSON.parse(fs.readFileSync(path, 'utf8')); } catch {}
if (!settings.mcpServers) settings.mcpServers = {};
settings.mcpServers.spendcontrol = {
  command: 'node',
  args: ['$INSTALL_DIR/index.js'],
  env: {
    VAULT_ADDRESS: '$VAULT_ADDRESS',
    AGENT_PRIVATE_KEY: '$AGENT_KEY',
    RPC_URL: '$RPC_URL'
  }
};
fs.writeFileSync(path, JSON.stringify(settings, null, 2));
"

echo -e "  ${CYAN}[2/3]${NC} Claude Code configured ${DIM}(~/.claude/settings.json)${NC}"

# Step 3: Done
echo -e "  ${CYAN}[3/3]${NC} Done!"
echo ""
echo -e "${GREEN}${BOLD}  SpendControl is ready.${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Open Claude Code (or restart if already open)"
echo -e "  2. Type ${CYAN}/mcp__spendcontrol__guide${NC} to load the vault guide"
echo -e "     Or just ask: ${DIM}\"Check my vault budget\"${NC}"
echo ""
echo -e "  Your agent will have these tools:"
echo -e "    ${CYAN}check_budget${NC}   — see available balance per token"
echo -e "    ${CYAN}spend${NC}          — send tokens (within your limits)"
echo -e "    ${CYAN}get_history${NC}    — view past transactions"
echo -e "    ${CYAN}get_vault_info${NC} — vault status and config"
echo ""
