#!/bin/bash
# SpendControl Agent Setup — run this ONCE to configure your agent

set -e

echo "=== SpendControl Agent Setup ==="
echo ""

# Check required tools
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found. Install Node.js first."; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "ERROR: npm not found. Install Node.js first."; exit 1; }

# Get vault address
read -p "Your vault address: " VAULT_ADDRESS
if [ -z "$VAULT_ADDRESS" ]; then echo "ERROR: vault address required"; exit 1; fi

# Get agent private key
read -sp "Agent private key (hidden): " AGENT_PRIVATE_KEY
echo ""
if [ -z "$AGENT_PRIVATE_KEY" ]; then echo "ERROR: private key required"; exit 1; fi

# Get RPC URL
read -p "RPC URL [https://eth.llamarpc.com]: " RPC_URL
RPC_URL=${RPC_URL:-https://eth.llamarpc.com}

# Clone and install MCP server
echo ""
echo "Installing MCP server..."
INSTALL_DIR="$HOME/.spendcontrol"
rm -rf "$INSTALL_DIR"
git clone --depth 1 https://github.com/spendcontrol/agentvault.git "$INSTALL_DIR" 2>/dev/null
cd "$INSTALL_DIR/mcp-server"
npm install --silent 2>/dev/null

MCP_PATH="$INSTALL_DIR/mcp-server/index.js"

echo ""
echo "=== Done! ==="
echo ""
echo "Add this to your Claude Code settings (~/.claude/settings.json):"
echo ""
echo '{
  "mcpServers": {
    "spendcontrol": {
      "command": "node",
      "args": ["'$MCP_PATH'"],
      "env": {
        "VAULT_ADDRESS": "'$VAULT_ADDRESS'",
        "AGENT_PRIVATE_KEY": "'$AGENT_PRIVATE_KEY'",
        "RPC_URL": "'$RPC_URL'"
      }
    }
  }
}'
echo ""
echo "After adding, restart Claude Code. Your agent will have these tools:"
echo "  check_budget  — see token balances and daily remaining"
echo "  spend         — send tokens with a mandatory reason"
echo "  get_history   — view past transactions"
echo "  get_vault_info — vault config and status"
echo ""
echo "Test it by asking your agent: 'Check my vault budget'"
