# SpendControl — Treasury Protocol for AI Agents

> Deposit tokens. Set spending rules. Your agent operates within limits. Every transaction recorded on-chain with a reason.

**Live:** [spendcontrol.xyz](https://spendcontrol.xyz) · **Docs:** [spendcontrol.xyz/docs](https://spendcontrol.xyz/docs/) · **Ethereum Mainnet** + Base Sepolia

---

## The Problem

AI agents need money to operate — API calls, compute, data feeds, on-chain transactions. But today you have two bad options:

1. **Give the agent full wallet access** — it can drain everything
2. **Manually approve every expense** — doesn't scale, kills autonomy

There's no infrastructure for giving an agent a **controlled budget** with hard spending limits enforced on-chain.

## The Solution

**SpendControl** is a smart contract protocol that creates a personal treasury for your AI agent:

```
You deposit tokens → Set per-token rules → Agent operates freely within limits
```

- **Any ERC20 token** — USDC, WETH, DAI, stETH, anything
- **Per-token spending limits** — daily caps and per-transaction caps, enforced by the contract
- **Mandatory expense reports** — every spend has an on-chain reason. Agent literally cannot spend without explaining why
- **Lido staking** — stake ETH, agent lives off the yield, principal locked forever
- **Instant pause** — one click to freeze all spending
- **Full audit trail** — every transaction visible on Etherscan with reason

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

---

## Hackathon Track Alignment

### 🏆 Synthesis Open Track

SpendControl is **infrastructure for the entire agent economy**. Any agent that needs to spend money needs controlled access to funds. We built the missing primitive: a multi-token treasury with smart-contract-enforced spending rules, expense reports, and Lido yield integration.

**What we shipped:**
- Smart contracts deployed on Ethereum Mainnet (EIP-1167 proxy, ~$1 per vault)
- Dashboard at [spendcontrol.xyz](https://spendcontrol.xyz)
- Python SDK, MCP Server, skill file, CLI integration
- Full documentation
- 24 tests, security audit against EthSkills checklist

### 🔵 stETH Agent Treasury (Lido)

SpendControl implements **exactly what this track asks for**: a contract primitive where a human gives an AI agent a yield-bearing operating budget backed by stETH, without giving the agent access to the principal.

**How it works:**
1. Owner calls `stakeETH(yieldOnly: true)` — ETH goes to Lido, stETH enters the vault
2. `stakedPrincipal` is recorded — agent can never touch it
3. stETH rebases daily (balance grows as Lido distributes staking rewards)
4. Anyone calls `harvestYield()` once per day — crystallizes new yield
5. `spendableYield()` — agent can only spend harvested yield
6. Agent calls `spend(stETH, recipient, amount, "reason")` — from yield only

**Principal is structurally inaccessible to the agent.** The contract enforces this — not a frontend, not a promise. Owner can withdraw principal anytime via `withdrawPrincipal()`.

### 🔵 Lido MCP

We built an **MCP server** that gives any AI agent (Claude Code, etc.) native tools to interact with Lido stETH through SpendControl:

- `check_budget(token)` — shows stETH balance, spendable yield, daily remaining
- `spend(token, to, amount, reason)` — spend from yield with mandatory reason
- `get_vault_info` — shows stakedPrincipal, pendingYield, spendableYield, yieldOnly status
- `get_history` — all transactions with reasons

Install: add to `~/.claude/settings.json`, agent gets native spend tools. No SDK code needed.

### 🤖 Let the Agent Cook — No Humans Required (Protocol Labs)

SpendControl enables **fully autonomous agents** that fund themselves:

1. Human stakes ETH once → Lido generates yield forever
2. Agent monitors its budget via `check_budget()`
3. Agent spends yield on API calls, compute, data feeds
4. Agent reports every expense on-chain with a reason
5. Human checks expense log whenever they want — or never

**The agent doesn't ask for permission on every spend. It asks once — when the rules are set.**

After setup, the human can walk away. The agent operates indefinitely within on-chain rules. Zero maintenance. Self-sustaining from staking yield.

### 📝 Agents With Receipts — ERC-8004 (Protocol Labs)

Every transaction in SpendControl is a **verifiable receipt**:

```solidity
event AgentSpent(
    address indexed agent,   // who spent
    address indexed token,   // what token
    address indexed to,      // where it went
    uint256 amount,          // how much
    string reason            // WHY (mandatory, stored on-chain)
);
```

**Reason is enforced at the contract level:**
```solidity
require(bytes(reason).length > 0, "Reason required");
```

The agent literally cannot execute a spend without providing an explanation. This creates an immutable, on-chain audit trail that anyone can verify. No opaque logs. No "trust us" dashboards. Pure on-chain accountability.

Additionally, `expenses[]` array stores every spend with timestamp, token, recipient, amount, and reason — queryable via `getExpense(index)` and `getRecentExpenses(count)`.

---

## Quick Start

### For Vault Owners

1. Open [spendcontrol.xyz](https://spendcontrol.xyz) and connect MetaMask
2. Create a vault (specify your agent's wallet address)
3. Deposit tokens (ETH, USDC, etc.)
4. Set per-token spending limits
5. Optionally: stake ETH via Lido for self-sustaining agent budget

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
tx = client.spend("0xUSDC", "0xRecipient", 1000000, "Paid for GPT-4 API call")
```

**MCP Server** for Claude Code — see [docs](https://spendcontrol.xyz/docs/).

---

## Contracts

| Contract | Description |
|----------|------------|
| `AgentVault.sol` | Multi-token treasury with spending limits, Lido staking, mandatory expense reports |
| `AgentVaultFactory.sol` | EIP-1167 minimal proxy factory — ~$1 per vault creation |

## Deployed

| Network | Factory | Explorer |
|---------|---------|----------|
| Ethereum Mainnet | `0x93e3F6F081F0f5bef1EF9CD42D7924E258e8073B` | [Etherscan](https://etherscan.io/address/0x93e3F6F081F0f5bef1EF9CD42D7924E258e8073B) |
| Base Sepolia | `0xF6CFA83764D0B1E0417a74FfB8d915985DFd3642` | [BaseScan](https://sepolia.basescan.org/address/0xF6CFA83764D0B1E0417a74FfB8d915985DFd3642) |

## Security

- **SafeERC20** — handles non-standard tokens (USDT doesn't return bool)
- **ReentrancyGuard** — on all state-changing functions
- **Mandatory reason** — agent cannot spend without on-chain explanation
- **Per-token limits** — enforced by smart contract, not frontend
- **Zero-address checks** — prevents permanent fund loss
- **Approval hygiene** — reset to 0 before re-approving
- **EIP-1167 proxy** — implementation contract is immutable
- **Pausable** — owner can freeze all spending instantly
- **Audited** against [EthSkills](https://ethskills.com) security checklist

## Testing

```bash
forge test  # 24 tests — deposits, spending, limits, staking, yield, pause, access control
```

## Stack

- **Contracts:** Solidity 0.8.20, Foundry
- **SDK:** Python, web3.py
- **MCP Server:** Node.js, ethers.js, @modelcontextprotocol/sdk
- **Dashboard:** HTML/JS, ethers.js
- **Chain:** Ethereum Mainnet + Base Sepolia

## Roadmap

- **x402 Integration** — Coinbase's HTTP 402 payment protocol. Agents will automatically pay for API calls directly from their vault when services return 402. The vault already supports arbitrary ERC20 spending — x402 client integration is the next step to enable pay-per-request for any x402-compatible API.
- **Multi-chain** — Deploy on Base, Arbitrum, Optimism for cheaper agent transactions
- **Gasless spending** — Meta-transactions so agents don't need ETH for gas
- **Spending analytics** — On-chain dashboards showing agent ROI (cost vs value generated)

## Links

- [Dashboard](https://spendcontrol.xyz)
- [Documentation](https://spendcontrol.xyz/docs/)
- [Skill File](https://spendcontrol.xyz/skill.md)
- [GitHub](https://github.com/spendcontrol/agentvault)

---

*Built for [The Synthesis](https://synthesis.md) hackathon. The first hackathon you can enter without a body.*
