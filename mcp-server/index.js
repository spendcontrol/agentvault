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
  'function deposit(address token, uint256 amount)',
  'function depositETH() payable',
  'function withdraw(address token, uint256 amount)',
  'function stakeETH(bool yieldOnly) payable',
  'function harvestYield()',
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
  'event Deposited(address indexed owner, address indexed token, uint256 amount)',
  'event StakedETH(address indexed owner, uint256 ethAmount, uint256 stETHReceived, bool yieldOnly)',
  'event YieldHarvested(uint256 amount, uint256 totalSpendable)',
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
  name: "yieldvault",
  version: "1.0.0",
});

// ---- check_budget ----
server.tool(
  "check_budget",
  "Returns token balances, daily remaining, limits for a specific token. Also lists all supported tokens.",
  {
    token: z.string().describe("Token contract address to check budget for"),
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
        `All supported tokens (${tokens.length}):`,
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

// ---- spend ----
server.tool(
  "spend",
  "Spend tokens from the vault to an address. Reason is required.",
  {
    token: z.string().describe("Token contract address to spend"),
    to: z.string().describe("Recipient address"),
    amount: z.string().describe('Amount of tokens to spend (e.g. "0.001" or "100")'),
    reason: z.string().describe("Why you are spending (stored on-chain, required)"),
  },
  async ({ token, to, amount, reason }) => {
    try {
      if (!ethers.isAddress(token)) {
        throw new Error(`Invalid token address: ${token}`);
      }
      if (!ethers.isAddress(to)) {
        throw new Error(`Invalid recipient address: ${to}`);
      }
      if (!reason) {
        throw new Error("Reason is required and must be non-empty");
      }

      const amountWei = ethers.parseEther(amount);
      if (amountWei <= 0n) {
        throw new Error("Amount must be greater than zero");
      }

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

// ---- get_history ----
server.tool(
  "get_history",
  "Get recent agent spending transactions from the vault",
  {},
  async () => {
    try {
      const provider = getProvider();
      const vault = getVault(provider);

      const currentBlock = await provider.getBlockNumber();
      // Look back ~7 days worth of blocks (~2s block time on Base)
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

      // Sort by block number descending (most recent first)
      entries.sort((a, b) => b.block - a.block);

      if (entries.length === 0) {
        return {
          content: [
            { type: "text", text: "No recent transactions found in the last ~7 days." },
          ],
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
        content: [
          { type: "text", text: `Error fetching history: ${err.message}` },
        ],
        isError: true,
      };
    }
  }
);

// ---- get_vault_info ----
server.tool(
  "get_vault_info",
  "Get vault configuration: owner, agent, paused status, all tokens with limits, and staking info",
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
        `Paused:             ${paused ? "YES" : "NO"}`,
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
        const [balance, dailyLimit, perTxLimit] = await Promise.all([
          vault.balanceOf(token),
          vault.effectiveDailyLimit(token),
          vault.effectivePerTxLimit(token),
        ]);
        lines.push(
          `  ${token}`,
          `    Balance:       ${fmtEth(balance)}`,
          `    Daily Limit:   ${fmtEth(dailyLimit)}`,
          `    Per-Tx Limit:  ${fmtEth(perTxLimit)}`,
        );
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    } catch (err) {
      return {
        content: [
          { type: "text", text: `Error fetching vault info: ${err.message}` },
        ],
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
