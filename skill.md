# AgentVault — AI Agent Treasury Protocol

You are an AI agent with access to an **AgentVault** — a smart contract that gives you a spending budget controlled by your human operator. Your human deposited tokens (USDC, WETH, wstETH, or any ERC20) into the vault and set spending rules. You can spend within those rules. You cannot exceed the limits.

## Your Vault

- **Vault address**: Set via `VAULT_ADDRESS` environment variable
- **Your private key**: Set via `AGENT_PRIVATE_KEY` environment variable
- **Network**: Base (RPC: set via `RPC_URL`, default `https://sepolia.base.org`)

## What You Can Do

### 1. Check your budget
Always check before spending.

```python
from yieldvault import VaultClient
import os

client = VaultClient(
    rpc_url=os.environ["RPC_URL"],
    vault_address=os.environ["VAULT_ADDRESS"],
    agent_private_key=os.environ["AGENT_PRIVATE_KEY"],
)

budget = client.check_budget()
# budget = {"balance": ..., "available_budget": ..., "daily_remaining": ..., "total_deposited": ..., "total_spent": ...}
```

### 2. Spend tokens
Send tokens from the vault to any address, with a reason.

```python
tx = client.spend(
    to_address="0xServiceAddress",
    amount_wei=1000000,            # e.g. 1 USDC (6 decimals)
    reason="Paid for GPT-4 API call"
)
```

### 3. Swap tokens via Uniswap
If you need a different token (e.g. vault holds WETH but you need USDC):

```python
tx = client.spend_and_swap(
    token_out="0xUSDC_ADDRESS",
    fee=3000,
    amount_in_wei=1000000000000000,
    amount_out_minimum=0,
    to_address=client.address,
    reason="Swapped WETH to USDC for API payment"
)
```

### 4. Check spending history
```python
history = client.get_history()
for tx in history:
    print(f"Sent {tx['amount']} to {tx['to']} — {tx['reason']}")
```

## Rules

1. **Always check budget first.** If `available_budget` is 0, you have nothing to spend.
2. **Never exceed daily limit.** Check `daily_remaining` — resets every 24h.
3. **Never exceed per-tx limit.** Split large payments if needed.
4. **Always provide a reason.** Your human reviews expense reports on-chain.
5. **The vault may be paused.** If paused, all spends fail. Wait.
6. **Token decimals matter.** USDC = 6 decimals, WETH = 18 decimals. Don't mix them up.

## MCP Server

If your harness supports MCP:

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

Tools: `check_budget`, `spend`, `spend_and_swap`, `get_history`, `get_vault_info`.

## Python SDK

```bash
cd /path/to/yieldvault/sdk/python && pip install -e .
```

## Links

- Dashboard: http://37.27.40.172:3000
- Explorer: https://sepolia.basescan.org
