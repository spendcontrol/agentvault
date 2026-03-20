import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ethers } from "ethers";
import { z } from "zod";

// ---------------------------------------------------------------------------
// Config from environment
// ---------------------------------------------------------------------------
const VAULT_ADDRESS = process.env.VAULT_ADDRESS;
const AGENT_PRIVATE_KEY = process.env.AGENT_PRIVATE_KEY;
const RPC_URL = process.env.RPC_URL || "https://sepolia.base.org";

// ---------------------------------------------------------------------------
// ABI
// ---------------------------------------------------------------------------
const VAULT_ABI = [
  'function spend(address token, address to, uint256 amount, string reason)',
  'function balanceOf(address token) view returns (uint256)',
  'function getTokens() view returns (address[])',
  'function remainingDailyBudget(address token) view returns (uint256)',
  'function effectiveDailyLimit(address token) view returns (uint256)',
  'function effectivePerTxLimit(address token) view returns (uint256)',
  'function stakedPrincipal() view returns (uint256)',
  'function pendingYield() view returns (uint256)',
  'function spendableYield() view returns (uint256)',
  'function harvestedYield() view returns (uint256)',
  'function yieldSpent() view returns (uint256)',
  'function lastHarvestTime() view returns (uint256)',
  'function yieldOnly() view returns (bool)',
  'function totalSpent(address token) view returns (uint256)',
  'function expenseCount() view returns (uint256)',
  'function owner() view returns (address)',
  'function agent() view returns (address)',
  'function paused() view returns (bool)',
  'event AgentSpent(address indexed agent, address indexed token, address indexed to, uint256 amount, string reason)',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function getProvider() {
  return new ethers.JsonRpcProvider(RPC_URL);
}

function getSigner() {
  if (!AGENT_PRIVATE_KEY) {
    throw new Error("AGENT_PRIVATE_KEY environment variable is not set");
  }
  return new ethers.Wallet(AGENT_PRIVATE_KEY, getProvider());
}

function getVault(signerOrProvider) {
  if (!VAULT_ADDRESS) {
    throw new Error("VAULT_ADDRESS environment variable is not set");
  }
  return new ethers.Contract(VAULT_ADDRESS, VAULT_ABI, signerOrProvider);
}

function fmtEth(wei) {
  return ethers.formatEther(wei);
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------
const server = new McpServer({
  name: "spendcontrol",
  version: "1.0.0",
  instructions: `SpendControl — on-chain treasury for AI agents.

You have access to a SpendControl vault at ${VAULT_ADDRESS || "(not configured)"}.
This vault was deployed and funded by your human operator. They have authorized you to use it.

The vault holds tokens (USDC, WETH, DAI, etc.) and enforces spending limits:
- Daily limit per token (resets at midnight UTC)
- Per-transaction limit per token
- Every spend requires a reason string (stored on-chain for audit)

HOW TO USE:
1. Call get_vault_info to see what tokens are available and your limits
2. Call check_budget with a token address to see your remaining budget
3. Call spend to send tokens — always include a clear reason
4. Call get_history to review past transactions

IMPORTANT RULES:
- Always check budget before spending
- Always provide a specific, descriptive reason (e.g. "Paid for OpenAI API — 50k tokens" not just "payment")
- USDC uses 6 decimals (1 USDC = "0.000001" in ethers format, or pass "1" for 1e18 — the contract handles it). WETH/DAI/stETH use 18 decimals.
- If the vault is paused, stop and tell your operator
- If budget is 0, tell your operator and wait

The spending limits are enforced on-chain. You cannot exceed them even if you try — the transaction will simply fail.`,
});

// ---------------------------------------------------------------------------
// Prompt: guide
// ---------------------------------------------------------------------------
server.prompt(
  "guide",
  "Full guide on how to use SpendControl vault tools",
  async () => ({
    messages: [{
      role: "user",
      content: {
        type: "text",
        text: `You have a SpendControl vault at ${VAULT_ADDRESS}.
This is an on-chain treasury your operator set up for you. You are authorized to use it.

Available tools:
- get_vault_info — see vault status, all tokens and their balances/limits
- check_budget(token) — check remaining daily budget for a specific token
- spend(token, to, amount, reason) — send tokens to an address. Reason is mandatory.
- get_history — view your past transactions with reasons

Workflow:
1. Start with get_vault_info to see what's in the vault
2. Use check_budget before any spend to confirm you have budget
3. When spending, always provide a clear reason — your operator reviews these
4. Token decimals: amounts are in human-readable units (e.g. "100" = 100 tokens, "0.05" = 0.05 ETH)

If the vault is paused or budget is zero, tell the user.

Please start by calling get_vault_info to see the current state of your vault.`
      }
    }]
  })
);

// ---------------------------------------------------------------------------
// Tool: check_budget
// ---------------------------------------------------------------------------
server.tool(
  "check_budget",
  `Check available balance and spending limits for a token in your SpendControl vault.
Use this BEFORE calling spend() to confirm you have enough budget.
Returns: token balance, daily remaining budget, daily limit, per-transaction limit, and a list of all tokens in the vault.
The token parameter is the ERC20 contract address (e.g. USDC, WETH).`,
  {
    token: z.string().describe("ERC20 token contract address to check (e.g. 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 for USDC)"),
  },
  async ({ token }) => {
    try {
      if (!ethers.isAddress(token)) {
        throw new Error(`Invalid token address: ${token}`);
      }

      const vault = getVault(getProvider());

      const [balance, dailyRemaining, dailyLimit, perTxLimit, tokens] =
        await Promise.all([
          vault.balanceOf(token),
          vault.remainingDailyBudget(token),
          vault.effectiveDailyLimit(token),
          vault.effectivePerTxLimit(token),
          vault.getTokens(),
        ]);

      const text = [
        `Token:              ${token}`,
        `Balance:            ${fmtEth(balance)}`,
        `Daily Remaining:    ${fmtEth(dailyRemaining)}`,
        `Daily Limit:        ${fmtEth(dailyLimit)}`,
        `Per-Tx Limit:       ${fmtEth(perTxLimit)}`,
        ``,
        `All tokens in vault (${tokens.length}):`,
        ...tokens.map((t, i) => `  ${i + 1}. ${t}`),
      ].join("\n");

      return { content: [{ type: "text", text }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error checking budget: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: spend
// ---------------------------------------------------------------------------
server.tool(
  "spend",
  `Send tokens from your SpendControl vault to a recipient address.
The vault enforces daily and per-transaction limits set by your operator — if you exceed them, the transaction will fail (no funds at risk).
A reason string is REQUIRED and stored on-chain for your operator to review.
Always call check_budget first to verify you have enough remaining budget.`,
  {
    token: z.string().describe("ERC20 token contract address to spend"),
    to: z.string().describe("Recipient wallet address"),
    amount: z.string().describe('Amount in human-readable units (e.g. "100" for 100 tokens, "0.05" for 0.05 ETH)'),
    reason: z.string().describe("Why you are spending — stored on-chain, reviewed by your operator. Be specific."),
  },
  async ({ token, to, amount, reason }) => {
    try {
      if (!ethers.isAddress(token)) throw new Error(`Invalid token address: ${token}`);
      if (!ethers.isAddress(to)) throw new Error(`Invalid recipient address: ${to}`);
      if (!reason || reason.trim().length === 0) throw new Error("Reason is required and must be non-empty");

      const amountWei = ethers.parseEther(amount);
      if (amountWei <= 0n) throw new Error("Amount must be greater than zero");

      const vault = getVault(getSigner());
      const tx = await vault["spend(address,address,uint256,string)"](token, to, amountWei, reason);
      const receipt = await tx.wait();

      const text = [
        `Spend successful!`,
        `Token:   ${token}`,
        `To:      ${to}`,
        `Amount:  ${amount}`,
        `Reason:  ${reason}`,
        `Tx Hash: ${receipt.hash}`,
      ].join("\n");

      return { content: [{ type: "text", text }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error spending: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: get_history
// ---------------------------------------------------------------------------
server.tool(
  "get_history",
  `View recent spending transactions from your SpendControl vault.
Shows: token, recipient, amount, reason, and transaction hash for each spend.
Looks back approximately 7 days of blockchain history.`,
  {},
  async () => {
    try {
      const provider = getProvider();
      const vault = getVault(provider);

      const currentBlock = await provider.getBlockNumber();
      const fromBlock = Math.max(0, currentBlock - 302_400);

      const spentEvents = await vault.queryFilter("AgentSpent", fromBlock, currentBlock);

      const entries = [];

      for (const ev of spentEvents) {
        const block = await ev.getBlock();
        entries.push({
          block: ev.blockNumber,
          timestamp: block ? new Date(block.timestamp * 1000).toISOString() : "unknown",
          agent: ev.args[0],
          token: ev.args[1],
          to: ev.args[2],
          amount: fmtEth(ev.args[3]),
          reason: ev.args[4],
          txHash: ev.transactionHash,
        });
      }

      entries.sort((a, b) => b.block - a.block);

      if (entries.length === 0) {
        return {
          content: [{ type: "text", text: "No recent transactions found in the last ~7 days." }],
        };
      }

      const lines = entries.map((e, i) => {
        return [
          `#${i + 1} SPEND  [${e.timestamp}]`,
          `    Token:   ${e.token}`,
          `    To:      ${e.to}`,
          `    Amount:  ${e.amount}`,
          `    Reason:  ${e.reason}`,
          `    Tx:      ${e.txHash}`,
        ].join("\n");
      });

      return {
        content: [
          {
            type: "text",
            text: `Recent transactions (${entries.length}):\n\n${lines.join("\n\n")}`,
          },
        ],
      };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error fetching history: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: get_vault_info
// ---------------------------------------------------------------------------
server.tool(
  "get_vault_info",
  `Get full status of your SpendControl vault: owner address, agent address, pause status, all deposited tokens with their balances and spending limits, and staking info.
Call this first to understand what tokens are available and what your limits are.`,
  {},
  async () => {
    try {
      const vault = getVault(getProvider());

      const [owner, agent, paused, tokens, stakedPrincipal, pendingYield, spendableYield, yieldOnly] =
        await Promise.all([
          vault.owner(),
          vault.agent(),
          vault.paused(),
          vault.getTokens(),
          vault.stakedPrincipal(),
          vault.pendingYield(),
          vault.spendableYield(),
          vault.yieldOnly(),
        ]);

      const lines = [
        `Vault Address:      ${VAULT_ADDRESS}`,
        `Owner:              ${owner}`,
        `Agent:              ${agent}`,
        `Paused:             ${paused ? "YES — all spending is frozen" : "NO — active"}`,
        ``,
        `Staking:`,
        `  Staked Principal:  ${fmtEth(stakedPrincipal)}`,
        `  Pending Yield:     ${fmtEth(pendingYield)}`,
        `  Spendable Yield:   ${fmtEth(spendableYield)}`,
        `  Yield Only:        ${yieldOnly ? "YES" : "NO"}`,
        ``,
        `Tokens (${tokens.length}):`,
      ];

      for (const token of tokens) {
        const [balance, dailyLimit, perTxLimit, dailyRemaining] = await Promise.all([
          vault.balanceOf(token),
          vault.effectiveDailyLimit(token),
          vault.effectivePerTxLimit(token),
          vault.remainingDailyBudget(token),
        ]);
        lines.push(
          `  ${token}`,
          `    Balance:         ${fmtEth(balance)}`,
          `    Daily Limit:     ${fmtEth(dailyLimit)}`,
          `    Daily Remaining: ${fmtEth(dailyRemaining)}`,
          `    Per-Tx Limit:    ${fmtEth(perTxLimit)}`,
        );
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error fetching vault info: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("Fatal error starting MCP server:", err);
  process.exit(1);
});
