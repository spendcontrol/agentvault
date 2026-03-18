# YieldVault — Operating Budget Protocol for AI Agents

> Stake ETH. Your agent lives off the yield. Principal stays untouched. Rules enforced by smart contracts.

## The Problem

AI agents need money to operate — paying for compute, API calls, data feeds. Today, you either give your agent full wallet access (scary) or manually fund it (doesn't scale). There's no way to give an agent a self-replenishing budget with hard spending limits enforced on-chain.

## The Solution

**YieldVault** is an on-chain protocol where:

1. **Human deposits ETH** → contract stakes via Lido → earns stETH yield (~3.5% APY)
2. **Principal is locked** — the agent can never touch it
3. **Yield flows to the agent** — as a spendable budget, within limits you set
4. **Smart contract enforces everything** — daily caps, per-tx limits, whitelists, pause

The agent operates freely within boundaries. The human stays in control. Everything is auditable on-chain.

```
Human sets rules → Agent operates within them → Ethereum enforces
```

## Architecture

```
┌──────────────────────────┐
│   YieldVaultFactory      │  Anyone can deploy a vault
│   createVault()          │
└───────────┬──────────────┘
            │ creates
┌───────────▼──────────────┐
│      YieldVault          │
│  ┌─────────────────────┐ │
│  │ Principal (locked)   │ │  ← Human's ETH, staked as wstETH
│  ├─────────────────────┤ │
│  │ Yield (spendable)   │ │  ← Agent's operating budget
│  ├─────────────────────┤ │
│  │ Rules:              │ │
│  │  • Daily limit      │ │
│  │  • Per-tx limit     │ │
│  │  • Whitelist        │ │
│  │  • Pause switch     │ │
│  └─────────────────────┘ │
└──────────────────────────┘
            │
┌───────────▼──────────────┐
│    Agent SDK (Python)    │  Any agent can plug in
│  check_budget()          │
│  spend(to, amount)       │
│  get_history()           │
└──────────────────────────┘
```

## Quick Start

### For Humans (Vault Owners)

1. Open the dashboard (`dashboard/index.html`)
2. Connect MetaMask
3. Create a vault — set your agent's address and spending limits
4. Deposit wstETH
5. Your agent is funded. Monitor spending from the dashboard.

### For Agent Developers

```python
from yieldvault import VaultClient

client = VaultClient(
    rpc_url="https://mainnet.base.org",
    vault_address="0x...",
    agent_private_key="0x..."
)

# Check budget
budget = client.check_budget()
print(f"Available: {budget['available_yield']} wei")

# Spend yield
tx = client.spend(recipient="0x...", amount=50000000000000000)

# View history
history = client.get_history()
```

### Install SDK

```bash
cd sdk/python
pip install -e .
```

## Contracts

| Contract | Description |
|----------|------------|
| `YieldVault.sol` | Core vault — deposit, yield tracking, spend with limits |
| `YieldVaultFactory.sol` | Factory — deploy personal vaults in one tx |
| `MockWstETH.sol` | Testnet mock for wstETH |
| `MockStETH.sol` | Testnet mock for stETH |

## Security Model

- **Principal isolation**: Agent can only access yield, never principal
- **Daily limits**: Cap total agent spending per 24h period
- **Per-tx limits**: Cap individual transaction size
- **Whitelist**: Restrict where agent can send funds
- **Pause**: Owner can instantly freeze agent spending
- **Owner exit**: Owner can always withdraw principal

## Testing

```bash
forge test -vv
```

15 tests covering: deposits, yield accrual, agent spending, limit enforcement, whitelist, pause, owner withdrawal, factory tracking.

## Built For

[The Synthesis](https://synthesis.md) — AI agents hackathon by the Ethereum ecosystem.

**Tracks**: stETH Agent Treasury (Lido), MetaMask Delegations, ERC-8004, Uniswap Agentic Finance, Let the Agent Cook, Synthesis Open Track

## Stack

- **Contracts**: Solidity 0.8.20, Foundry
- **SDK**: Python, web3.py
- **Dashboard**: Vanilla HTML/JS, ethers.js
- **Chain**: Base (Sepolia testnet → Mainnet)
