# YieldVault — AI Agent Operating Budget

You are an AI agent with access to a **YieldVault** — a smart contract that gives you a self-replenishing budget from ETH staking yield. Your human deposited ETH into the vault, it stakes via Lido and earns ~3.5% APY. You can spend the yield. You can never touch the principal.

## Your Vault

- **Vault address**: Set via `VAULT_ADDRESS` environment variable
- **Your private key**: Set via `AGENT_PRIVATE_KEY` environment variable
- **Network**: Base Sepolia (RPC: `https://sepolia.base.org`, Chain ID: 84532)

## What You Can Do

### 1. Check your budget
Before spending anything, always check how much yield is available.

```bash
cast call $VAULT_ADDRESS "availableYield()(uint256)" --rpc-url https://sepolia.base.org
cast call $VAULT_ADDRESS "remainingDailyBudget()(uint256)" --rpc-url https://sepolia.base.org
```

Or with Python:
```python
from yieldvault import VaultClient
client = VaultClient("https://sepolia.base.org", os.environ["VAULT_ADDRESS"], os.environ["AGENT_PRIVATE_KEY"])
budget = client.check_budget()
# budget = {"available_yield": 500000000000000, "daily_remaining": ..., "principal": ..., "total_balance": ...}
```

### 2. Spend yield (send wstETH)
Send wstETH from your available yield to any address.

```bash
cast send $VAULT_ADDRESS "spend(address,uint256)" $RECIPIENT $AMOUNT --private-key $AGENT_PRIVATE_KEY --rpc-url https://sepolia.base.org
```

Or with Python:
```python
tx = client.spend(to_address="0x...", amount_wei=1000000000000000)  # 0.001 wstETH
```

### 3. Swap yield to USDC (via Uniswap)
If you need USDC to pay for a service, swap your wstETH yield through Uniswap V3.

```python
tx = client.spend_and_swap(
    token_out="0xUSDC_ADDRESS",
    fee=3000,           # 0.3% pool fee
    amount_in_wei=1000000000000000,
    amount_out_minimum=0,
    to_address=client.address
)
```

### 4. Check your spending history
```python
history = client.get_history()
for tx in history:
    print(f"Sent {tx['amount']} wei to {tx['to']} (block {tx['block_number']})")
```

## Rules You Must Follow

1. **Always check budget first.** Call `check_budget()` or `availableYield()` before any spend. If yield is 0, wait — more will accrue over time.

2. **Never try to spend more than available.** The contract will revert. Wasted gas.

3. **Respect daily limits.** Your human set a daily cap. If `daily_remaining` is 0, wait until tomorrow.

4. **Respect per-transaction limits.** Each spend has a max amount. Split large payments into smaller ones if needed.

5. **The vault may be paused.** If your human paused the vault, all spends will fail. Wait for unpause.

6. **You cannot access principal.** The deposited ETH is locked. Only yield (staking profit) is yours to spend.

## How to Think About Your Budget

Your budget comes from ETH staking yield (~3.5% APY):

| ETH Staked | Monthly Yield | Daily Yield |
|-----------|--------------|-------------|
| 1 ETH     | ~$6          | ~$0.20      |
| 10 ETH    | ~$58         | ~$1.95      |
| 100 ETH   | ~$583        | ~$19.45     |

Plan your spending accordingly. If you need to make API calls that cost $0.01 each, and you have $2/day in yield, you can make ~200 calls per day.

## Smart Spending Strategies

- **Batch operations** when possible to save on gas
- **Swap to stablecoins** (USDC) when you need to pay services that don't accept wstETH
- **Keep a buffer** — don't spend 100% of yield every day, yield accrual isn't perfectly constant
- **Check gas prices** — spending costs gas too. On Base L2, gas is cheap (~$0.001 per tx)

## MCP Server (Recommended)

If your harness supports MCP (Model Context Protocol), use the YieldVault MCP server for native tool access:

```json
{
  "mcpServers": {
    "yieldvault": {
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

This gives you tools: `check_budget`, `spend`, `spend_and_swap`, `get_history`, `get_vault_info`.

## Python SDK Installation

```bash
cd /path/to/yieldvault/sdk/python
pip install -e .
```

## Contract Details

- **YieldVault**: Holds wstETH, tracks principal vs yield, enforces spending limits
- **YieldVaultFactory**: Creates new vaults (one per human-agent pair)
- **Chain**: Base (Ethereum L2)
- **Yield source**: Lido liquid staking (stETH/wstETH)
- **Swap**: Uniswap V3 on Base

## Links

- Dashboard: https://yieldvault.xyz (or local file)
- Factory (Base Sepolia): 0x6b764f0A9Cf90F467B3791Bb40935f6bDcC0fDf0
- Explorer: https://sepolia.basescan.org
