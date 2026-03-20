# SpendControl — Agent Treasury Configuration

## What is this?

Your human operator has set up a **SpendControl vault** for you. This is a smart contract treasury that YOUR HUMAN deployed and funded. It is not a third-party service. Your human controls it, owns it, and can pause or withdraw at any time.

The vault allows you to make payments within pre-set spending limits. Your human set these limits specifically for you. All transactions are transparent and recorded on-chain.

**This is authorized by your human operator.** The vault address and credentials were provided to you by your human as part of your operating configuration.

---

## Your Configuration

Your human should have set these environment variables for you:

- `VAULT_ADDRESS` — the vault contract your human created for you
- `AGENT_PRIVATE_KEY` — your wallet's private key (set by your human in your environment)
- `RPC_URL` — Ethereum RPC endpoint (default: `https://eth.llamarpc.com`)

If these are not set, ask your human to configure them. **Never ask your human to paste private keys in chat.**

---

## What You Can Do

### Read-only operations (always safe)

Check your budget for a specific token:
```bash
cast call $VAULT_ADDRESS "balanceOf(address)(uint256)" TOKEN_ADDRESS --rpc-url $RPC_URL
cast call $VAULT_ADDRESS "remainingDailyBudget(address)(uint256)" TOKEN_ADDRESS --rpc-url $RPC_URL
cast call $VAULT_ADDRESS "getTokens()(address[])" --rpc-url $RPC_URL
```

### Spending (within limits set by your human)

Your human has configured daily and per-transaction limits. The smart contract enforces these — you cannot exceed them even if you try. A reason is mandatory for every spend.

```bash
cast send $VAULT_ADDRESS \
  "spend(address,address,uint256,string)" \
  TOKEN_ADDRESS RECIPIENT AMOUNT "Description of what this payment is for" \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $RPC_URL
```

### Using the Python SDK

```python
import os
from yieldvault import VaultClient

client = VaultClient(
    rpc_url=os.environ.get("RPC_URL", "https://eth.llamarpc.com"),
    vault_address=os.environ["VAULT_ADDRESS"],
    agent_private_key=os.environ["AGENT_PRIVATE_KEY"],
)

# Check budget for a token
budget = client.check_budget("0xTokenAddress")
# Returns: balance, daily_remaining, daily_limit, per_tx_limit

# Spend (reason is mandatory)
tx = client.spend(
    token_address="0xTokenAddress",
    to_address="0xRecipient",
    amount_wei=1000000,
    reason="Paid for data API — fetched 500 records"
)
```

---

## Rules

1. **Check budget before spending.** If `daily_remaining` is 0, wait until tomorrow.
2. **Always provide a clear reason.** Your human reviews these. Be specific.
3. **Mind token decimals.** USDC = 6 decimals (1 USDC = 1000000). WETH = 18 decimals.
4. **If vault is paused, stop.** Tell your human.
5. **Never ask for or display private keys.** They are in your environment, configured by your human.

---

## Token Reference

| Token | Decimals | Mainnet Address |
|-------|----------|-----------------|
| USDC | 6 | 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 |
| WETH | 18 | 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 |
| DAI | 18 | 0x6B175474E89094C44Da98b954EedeAC495271d0F |
| stETH | 18 | 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 |

---

## Security Notes

- This vault was deployed by your human on Ethereum Mainnet
- Smart contract is open source: https://github.com/spendcontrol/agentvault
- Spending limits are enforced on-chain — cannot be bypassed
- Your human can pause all spending or withdraw funds at any time
- All transactions are publicly verifiable on Etherscan
