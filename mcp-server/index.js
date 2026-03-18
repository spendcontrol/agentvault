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
  "function deposit(uint256 amount)",
  "function withdraw(uint256 amount)",
  "function spend(address to, uint256 amount)",
  "function spend(address to, uint256 amount, string reason)",
  "function spendAndSwap(address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum, address to) returns (uint256)",
  "function spendAndSwap(address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum, address to, string reason) returns (uint256)",
  "function availableBudget() view returns (uint256)",
  "function remainingDailyBudget() view returns (uint256)",
  "function getStats() view returns (uint256, uint256, uint256, uint256, uint256)",
  "function totalDeposited() view returns (uint256)",
  "function totalSpent() view returns (uint256)",
  "function owner() view returns (address)",
  "function agent() view returns (address)",
  "function token() view returns (address)",
  "function dailyLimit() view returns (uint256)",
  "function perTxLimit() view returns (uint256)",
  "function paused() view returns (bool)",
  "function expenseCount() view returns (uint256)",
  "event AgentSpent(address indexed agent, address indexed to, uint256 amount, string reason)",
  "event AgentSwapped(address indexed agent, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed to, string reason)",
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
  "Returns available budget, daily remaining, total deposited and spent in human-readable format",
  {},
  async () => {
    try {
      const vault = getVault(getProvider());

      const [balance, totalDeposited, totalSpent, availableBudget, dailyRemaining] =
        await vault.getStats();

      const text = [
        `Available Budget:   ${fmtEth(availableBudget)}`,
        `Daily Remaining:    ${fmtEth(dailyRemaining)}`,
        `Vault Balance:      ${fmtEth(balance)}`,
        `Total Deposited:    ${fmtEth(totalDeposited)}`,
        `Total Spent:        ${fmtEth(totalSpent)}`,
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
  "Spend tokens from the vault to an address, with an optional reason",
  {
    to: z.string().describe("Recipient address"),
    amount: z.string().describe('Amount of tokens to spend (e.g. "0.001" or "100" for USDC)'),
    reason: z.string().optional().describe("Why you are spending (stored on-chain)"),
  },
  async ({ to, amount, reason }) => {
    try {
      if (!ethers.isAddress(to)) {
        throw new Error(`Invalid recipient address: ${to}`);
      }

      const amountWei = ethers.parseEther(amount);
      if (amountWei <= 0n) {
        throw new Error("Amount must be greater than zero");
      }

      const vault = getVault(getSigner());
      const tx = reason
        ? await vault["spend(address,uint256,string)"](to, amountWei, reason)
        : await vault["spend(address,uint256)"](to, amountWei);
      const receipt = await tx.wait();

      const text = [
        `Spend successful!`,
        `To:      ${to}`,
        `Amount:  ${amount}`,
        reason ? `Reason:  ${reason}` : null,
        `Tx Hash: ${receipt.hash}`,
      ].filter(Boolean).join("\n");

      return { content: [{ type: "text", text }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error spending: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ---- spend_and_swap ----
server.tool(
  "spend_and_swap",
  "Swap vault tokens to another token via Uniswap V3 and send to an address",
  {
    token_out: z.string().describe("Address of the token to receive"),
    amount: z.string().describe('Amount of vault tokens to swap (e.g. "0.01")'),
    min_out: z
      .string()
      .default("0")
      .describe('Minimum output amount (default "0")'),
    to: z.string().describe("Recipient address for the swapped tokens"),
  },
  async ({ token_out, amount, min_out, to }) => {
    try {
      if (!ethers.isAddress(token_out)) {
        throw new Error(`Invalid token_out address: ${token_out}`);
      }
      if (!ethers.isAddress(to)) {
        throw new Error(`Invalid recipient address: ${to}`);
      }

      const amountWei = ethers.parseEther(amount);
      if (amountWei <= 0n) {
        throw new Error("Amount must be greater than zero");
      }
      const minOutWei = ethers.parseEther(min_out);

      const vault = getVault(getSigner());
      const fee = 3000; // Uniswap 0.3% pool fee tier
      const tx = await vault.spendAndSwap(
        token_out,
        fee,
        amountWei,
        minOutWei,
        to
      );
      const receipt = await tx.wait();

      // Try to parse the YieldSwapped event for actual output amount
      let amountOutStr = "unknown";
      for (const log of receipt.logs) {
        try {
          const parsed = vault.interface.parseLog({
            topics: log.topics,
            data: log.data,
          });
          if (parsed && parsed.name === "AgentSwapped") {
            amountOutStr = fmtEth(parsed.args.amountOut);
            break;
          }
        } catch {
          // not our event, skip
        }
      }

      const text = [
        `Swap successful!`,
        `Token Out: ${token_out}`,
        `Amount In: ${amount} wstETH`,
        `Amount Out: ${amountOutStr}`,
        `Recipient: ${to}`,
        `Tx Hash:   ${receipt.hash}`,
      ].join("\n");

      return { content: [{ type: "text", text }] };
    } catch (err) {
      return {
        content: [
          { type: "text", text: `Error swapping yield: ${err.message}` },
        ],
        isError: true,
      };
    }
  }
);

// ---- get_history ----
server.tool(
  "get_history",
  "Get recent agent transactions (withdrawals and swaps) from the vault",
  {},
  async () => {
    try {
      const provider = getProvider();
      const vault = getVault(provider);

      const currentBlock = await provider.getBlockNumber();
      // Look back ~7 days worth of blocks (~2s block time on Base)
      const fromBlock = Math.max(0, currentBlock - 302_400);

      const [withdrawEvents, swapEvents] = await Promise.all([
        vault.queryFilter("AgentSpent", fromBlock, currentBlock),
        vault.queryFilter("AgentSwapped", fromBlock, currentBlock),
      ]);

      const entries = [];

      for (const ev of withdrawEvents) {
        const block = await ev.getBlock();
        entries.push({
          type: "withdraw",
          block: ev.blockNumber,
          timestamp: block ? new Date(block.timestamp * 1000).toISOString() : "unknown",
          agent: ev.args.agent,
          to: ev.args.to,
          amount: fmtEth(ev.args.amount),
          txHash: ev.transactionHash,
        });
      }

      for (const ev of swapEvents) {
        const block = await ev.getBlock();
        entries.push({
          type: "swap",
          block: ev.blockNumber,
          timestamp: block ? new Date(block.timestamp * 1000).toISOString() : "unknown",
          agent: ev.args.agent,
          tokenOut: ev.args.tokenOut,
          amountIn: fmtEth(ev.args.amountIn),
          amountOut: fmtEth(ev.args.amountOut),
          to: ev.args.to,
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
        if (e.type === "withdraw") {
          return [
            `#${i + 1} WITHDRAW  [${e.timestamp}]`,
            `    To:      ${e.to}`,
            `    Amount:  ${e.amount} wstETH`,
            `    Tx:      ${e.txHash}`,
          ].join("\n");
        }
        return [
          `#${i + 1} SWAP  [${e.timestamp}]`,
          `    Token Out: ${e.tokenOut}`,
          `    In:        ${e.amountIn} wstETH`,
          `    Out:       ${e.amountOut}`,
          `    To:        ${e.to}`,
          `    Tx:        ${e.txHash}`,
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
  "Get vault configuration: owner, agent, daily limit, per-tx limit, paused status",
  {},
  async () => {
    try {
      const vault = getVault(getProvider());

      const [owner, agent, dailyLimit, perTxLimit, paused] = await Promise.all([
        vault.owner(),
        vault.agent(),
        vault.dailyLimit(),
        vault.perTxLimit(),
        vault.paused(),
      ]);

      const text = [
        `Vault Address:  ${VAULT_ADDRESS}`,
        `Owner:          ${owner}`,
        `Agent:          ${agent}`,
        `Daily Limit:    ${fmtEth(dailyLimit)} wstETH`,
        `Per-Tx Limit:   ${fmtEth(perTxLimit)} wstETH`,
        `Paused:         ${paused ? "YES" : "NO"}`,
      ].join("\n");

      return { content: [{ type: "text", text }] };
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
