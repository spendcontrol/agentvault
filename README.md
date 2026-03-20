# SpendControl — Treasury Protocol for AI Agents

> Deposit tokens. Set spending rules. Your agent operates within limits. Every transaction recorded on-chain.

## The Problem

AI agents need money to operate — API calls, compute, data feeds. But giving an agent full wallet access is dangerous. And manually funding every expense doesn't scale. There's no way to give an agent a budget with hard spending limits enforced on-chain.

## The Solution

**SpendControl** is a smart contract protocol where:

1. **You deposit any token** — USDC, WETH, ETH, or any ERC20
2. **You set per-token spending limits** — daily caps, per-transaction caps, whitelists
3. **Your agent spends within those limits** — every transaction has a mandatory reason
4. **Everything is on-chain** — full audit trail, pause anytime, withdraw anytime

Optional: **Stake ETH via Lido** → stETH rebases automatically → agent pays for itself from staking yield.

## Architecture

```
AgentVaultFactory (EIP-1167 proxy — ~$1 per vault)
    │
    ├── AgentVault #1 (User A)
    │   ├── USDC: $5,000  (daily: 100, per-tx: 50)
    │   ├── WETH: 2 ETH   (daily: 0.1, per-tx: 0.05)
    │   └── stETH: 10 ETH (yield-only mode, principal locked)
    │
    └── AgentVault #2 (User B)
        └── USDC: $1,000  (daily: 50, per-tx: 25)
```

## Quick Start

### For Vault Owners

1. Open the [dashboard](https://spendcontrol.xyz) and connect MetaMask
2. Create a vault (specify your agent's wallet address)
3. Deposit tokens (ETH, USDC, etc.)
4. Set per-token spending limits
5. Share the vault address with your agent

### For Agent Developers

**Quickest way** — paste this to your agent:
```
Read this skill file: https://spendcontrol.xyz/skill.md
My vault address: 0xYourVault
```

**Python SDK:**
```python
from yieldvault import VaultClient

client = VaultClient(
    rpc_url="https://eth.llamarpc.com",
    vault_address="0xYourVault",
    agent_private_key=os.environ["AGENT_PRIVATE_KEY"],
)

budget = client.check_budget("0xUSDC_ADDRESS")
tx = client.spend("0xUSDC", "0xRecipient", 1000000, "API payment")
```

**MCP Server** for Claude Code — see [docs](https://spendcontrol.xyz/docs/).

## Contracts

| Contract | Description |
|----------|------------|
| `AgentVault.sol` | Multi-token treasury with spending limits, Lido staking, expense reports |
| `AgentVaultFactory.sol` | EIP-1167 proxy factory — ~$1 per vault creation |

## Deployed

| Network | Factory | Explorer |
|---------|---------|----------|
| Ethereum Mainnet | `0x93e3F6F081F0f5bef1EF9CD42D7924E258e8073B` | [Etherscan](https://etherscan.io/address/0x93e3F6F081F0f5bef1EF9CD42D7924E258e8073B) |
| Base Sepolia | `0xF6CFA83764D0B1E0417a74FfB8d915985DFd3642` | [BaseScan](https://sepolia.basescan.org/address/0xF6CFA83764D0B1E0417a74FfB8d915985DFd3642) |

## Security

- **SafeERC20** — handles non-standard tokens (USDT)
- **ReentrancyGuard** — on all state-changing functions
- **Mandatory reason** — agent cannot spend without explanation
- **Per-token limits** — enforced by smart contract
- **Zero-address checks** — prevents fund loss
- **EIP-1167 proxy** — implementation immutable
- **Pausable** — owner can freeze instantly

## Testing

```bash
forge test  # 24 tests
```

## Stack

- **Contracts:** Solidity 0.8.20, Foundry
- **SDK:** Python, web3.py
- **MCP Server:** Node.js, ethers.js, @modelcontextprotocol/sdk
- **Dashboard:** HTML/JS, ethers.js
- **Chain:** Ethereum Mainnet + Base Sepolia

## Built For

[The Synthesis](https://synthesis.md) — AI agents hackathon by the Ethereum ecosystem.

**Tracks:** Lido stETH Agent Treasury, ERC-8004, MetaMask Delegations, Synthesis Open Track

## Links

- [Dashboard](https://spendcontrol.xyz)
- [Documentation](https://spendcontrol.xyz/docs/)
- [Skill File](https://spendcontrol.xyz/skill.md)
- [GitHub](https://github.com/spendcontrol/app)
