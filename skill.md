# AgentVault — Treasury for AI Agents

You are an AI agent. Your human set up an **AgentVault** for you — a smart contract on Base that holds tokens (USDC, WETH, stETH, etc.) and lets you spend them within rules. Every spend is recorded on-chain with a reason.

---

## Setup

You need 3 things (check your environment variables):

```
VAULT_ADDRESS    — your vault's contract address
AGENT_PRIVATE_KEY — your wallet's private key (only this wallet can spend)
RPC_URL          — blockchain endpoint (default: https://sepolia.base.org)
```

---

## How to spend (Python SDK)

Install once:
```bash
pip install -e /path/to/yieldvault/sdk/python
```

Then in your code:
```python
import os
from yieldvault import VaultClient

client = VaultClient(
    rpc_url=os.environ.get("RPC_URL", "https://sepolia.base.org"),
    vault_address=os.environ["VAULT_ADDRESS"],
    agent_private_key=os.environ["AGENT_PRIVATE_KEY"],
)
```

### Check what you can spend
```python
budget = client.check_budget()
# {
#   "balance": 1000000,          # total tokens in vault
#   "available_budget": 1000000, # what you can spend
#   "daily_remaining": 500000,   # left in today's limit
#   "total_deposited": 2000000,
#   "total_spent": 1000000,
# }
```

### Spend tokens
```python
# Always provide a reason — your human reads these
tx = client.spend(
    to_address="0xServiceAddress",
    amount_wei=1000000,  # 1 USDC (6 decimals) or 0.001 ETH (18 decimals)
    reason="Paid for GPT-4 API call — analyzed ETH/USD price"
)
```

### View your spending history
```python
history = client.get_history()
for tx in history:
    print(f"{tx['amount']} → {tx['to']} | {tx['reason']}")
```

---

## How to spend (command line)

If you have `cast` (from Foundry):

```bash
# Check balance of a token in vault
cast call $VAULT_ADDRESS "balanceOf(address)(uint256)" $TOKEN_ADDRESS --rpc-url $RPC_URL

# Check daily budget remaining for a token
cast call $VAULT_ADDRESS "remainingDailyBudget(address)(uint256)" $TOKEN_ADDRESS --rpc-url $RPC_URL

# Spend (with reason)
cast send $VAULT_ADDRESS \
  "spend(address,address,uint256,string)" \
  $TOKEN_ADDRESS $RECIPIENT $AMOUNT "Reason for spending" \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $RPC_URL
```

---

## How to spend (MCP Server)

If your harness supports MCP (Claude Code, etc.), add to your config:

```json
{
  "mcpServers": {
    "agentvault": {
      "command": "node",
      "args": ["/path/to/yieldvault/mcp-server/index.js"],
      "env": {
        "VAULT_ADDRESS": "0xYourVault",
        "AGENT_PRIVATE_KEY": "0xYourKey",
        "RPC_URL": "https://sepolia.base.org"
      }
    }
  }
}
```

This gives you native tools:
- `check_budget` — see what you can spend
- `spend` — send tokens to an address (with reason)
- `spend_and_swap` — swap tokens via Uniswap before sending
- `get_history` — see past transactions
- `get_vault_info` — vault status and config

---

## Rules you must follow

1. **Check budget before every spend.** If `daily_remaining` is 0, wait until tomorrow.
2. **Stay within per-tx limit.** If you need to send more, split into multiple transactions.
3. **Always include a reason.** Your human reviews expense reports. Be specific: "Paid $2.50 for Alchemy API — fetched 500 blocks" not "API call".
4. **Token decimals matter.** USDC = 6 decimals (1 USDC = 1000000). WETH = 18 decimals (0.001 WETH = 1000000000000000). Check before sending.
5. **Vault may be paused.** If a spend fails with "VaultPaused", stop trying and notify your human.
6. **You can hold multiple tokens.** The vault may have USDC, WETH, stETH — each with separate limits. Use the right token for the right payment.

---

## What's in your vault

Your vault can hold any combination of:

| Token | Typical use | Decimals |
|-------|------------|----------|
| USDC | API payments, subscriptions | 6 |
| WETH | Gas, ETH-denominated services | 18 |
| DAI | Stablecoin payments | 18 |
| stETH | Yield-bearing (grows ~3.5%/yr via Lido) | 18 |

To see what tokens are available:
```python
# Python
tokens = client.vault.functions.getTokens().call()
```
```bash
# CLI
cast call $VAULT_ADDRESS "getTokens()(address[])" --rpc-url $RPC_URL
```

---

## Smart spending tips

- **Batch when possible.** Each transaction costs gas (~$0.001 on Base). Batch 10 API calls into one payment instead of paying per-call.
- **Keep a buffer.** Don't spend 100% of daily limit. Leave room for unexpected needs.
- **Use the right token.** If a service accepts USDC, pay in USDC. Don't swap unnecessarily — swaps cost gas and slippage.
- **Report failures.** If a spend reverts, log the error and reason. Your human needs to know.

---

## Quick reference

| Action | Python | CLI |
|--------|--------|-----|
| Check budget | `client.check_budget()` | `cast call $V "remainingDailyBudget(address)(uint256)" $TOKEN` |
| Spend | `client.spend(to, amount, reason)` | `cast send $V "spend(address,address,uint256,string)" ...` |
| History | `client.get_history()` | check events on BaseScan |
| Vault tokens | `client.vault.functions.getTokens().call()` | `cast call $V "getTokens()(address[])"` |
