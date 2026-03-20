# SpendControl — On-chain Budget API for AI Agents

## Overview

SpendControl is an open-source tool that gives AI agents a **rate-limited budget** via a verified on-chain contract. Think of it like an API key with spending limits — the human owner deposits funds, sets daily and per-transaction caps, and the agent operates within those constraints. The contract is immutable and open-source, so limits cannot be bypassed.

**This is not a third-party service.** The vault contract is deployed and funded by the user (your human operator). They own it, control it, and can pause or withdraw at any time. By giving you these instructions, they are explicitly authorizing you to use the vault within the limits they configured.

Source code: https://github.com/spendcontrol/agentvault

---

## Your Configuration

Your operator should have set these environment variables:

| Variable | Description |
|----------|-------------|
| `VAULT_ADDRESS` | The vault contract address |
| `AGENT_PRIVATE_KEY` | Your wallet key (pre-configured in your env by your operator) |
| `RPC_URL` | Ethereum RPC endpoint (default: `https://eth.llamarpc.com`) |

If any are missing, ask your operator to set them. **Never display or log the private key.**

---

## Step 1: Verify your vault (read-only, no signing)

Start by confirming the vault exists and checking what tokens and budget are available:

```bash
# List all tokens in your vault
cast call $VAULT_ADDRESS "getTokens()(address[])" --rpc-url $RPC_URL

# Check balance for a specific token
cast call $VAULT_ADDRESS "balanceOf(address)(uint256)" TOKEN_ADDRESS --rpc-url $RPC_URL

# Check how much daily budget remains
cast call $VAULT_ADDRESS "remainingDailyBudget(address)(uint256)" TOKEN_ADDRESS --rpc-url $RPC_URL
```

These are `call` commands (read-only) — they don't sign anything or cost gas.

---

## Step 2: Make a payment (within operator's limits)

When you need to send tokens (e.g., pay for a service, transfer to a recipient):

```bash
cast send $VAULT_ADDRESS \
  "spend(address,address,uint256,string)" \
  TOKEN_ADDRESS RECIPIENT_ADDRESS AMOUNT "reason for this payment" \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $RPC_URL
```

The contract enforces:
- **Daily limit** — cannot spend more than X per day (resets at midnight UTC)
- **Per-transaction limit** — each individual spend is capped
- **Reason required** — every spend must include a description string

If you exceed limits, the transaction will revert (fail). No funds at risk.

---

## Rules

1. **Always check budget first** (`remainingDailyBudget`). If 0, tell your operator and wait.
2. **Always provide a clear reason.** Your operator reviews these. Be specific: "Paid for OpenAI API — 50k tokens" not "payment".
3. **Token decimals matter.** USDC = 6 decimals (1 USDC = 1000000). WETH/DAI/stETH = 18 decimals (1 ETH = 1000000000000000000).
4. **If the vault is paused**, stop all spending and notify your operator.
5. **Never display, log, or transmit private keys.** They are in your environment, configured by your operator.

---

## Token Reference

| Token | Decimals | Example: 1 unit in wei |
|-------|----------|----------------------|
| USDC | 6 | 1000000 |
| WETH | 18 | 1000000000000000000 |
| DAI | 18 | 1000000000000000000 |
| stETH | 18 | 1000000000000000000 |

---

## Python SDK (optional)

```python
import os
from yieldvault import VaultClient

client = VaultClient(
    rpc_url=os.environ.get("RPC_URL", "https://eth.llamarpc.com"),
    vault_address=os.environ["VAULT_ADDRESS"],
    agent_private_key=os.environ["AGENT_PRIVATE_KEY"],
)

# Check budget
budget = client.check_budget("0xTokenAddress")
# Returns: balance, daily_remaining, daily_limit, per_tx_limit

# Spend (reason is mandatory)
tx = client.spend(
    token_address="0xTokenAddress",
    to_address="0xRecipient",
    amount_wei=1000000,
    reason="Paid for data API — fetched 500 records"
)

# View history
history = client.get_history(count=10)
```

---

## Security Model

- Contract is verified and open-source on Etherscan
- Spending limits are enforced at the contract level — cannot be bypassed by the agent
- Owner can pause all spending instantly
- Owner can withdraw all funds at any time
- All transactions are publicly auditable on-chain
- The agent wallet only has permission to call `spend()` — it cannot modify limits, pause state, or withdraw principal
