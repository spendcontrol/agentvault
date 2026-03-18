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
  "function depositETH() payable",
  "function spend(address to, uint256 amount)",
  "function spendAndSwap(address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum, address to) returns (uint256)",
  "function availableYield() view returns (uint256)",
  "function remainingDailyBudget() view returns (uint256)",
  "function getStats() view returns (uint256, uint256, uint256, uint256, uint256)",
  "function principalWstETH() view returns (uint256)",
  "function totalYieldSpent() view returns (uint256)",
  "function owner() view returns (address)",
  "function agent() view returns (address)",
  "function dailyLimit() view returns (uint256)",
  "function perTxLimit() view returns (uint256)",
  "function paused() view returns (bool)",
  "event YieldWithdrawn(address indexed agent, address indexed to, uint256 amount)",
  "event YieldSwapped(address indexed agent, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed to)",
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
  "Returns available yield, daily remaining budget, principal, and total balance in human-readable format",
  {},
  async () => {
    try {
      const vault = getVault(getProvider());

      const [availableYield, dailyRemaining, principal, totalYieldSpent] =
        await Promise.all([
          vault.availableYield(),
          vault.remainingDailyBudget(),
          vault.principalWstETH(),
          vault.totalYieldSpent(),
        ]);

      const totalBalance = principal + availableYield;

      const text = [
        `Available Yield:    ${fmtEth(availableYield)} wstETH`,
        `Daily Remaining:    ${fmtEth(dailyRemaining)} wstETH`,
        `Principal:          ${fmtEth(principal)} wstETH`,
        `Total Balance:      ${fmtEth(totalBalance)} wstETH`,
        `Total Yield Spent:  ${fmtEth(totalYieldSpent)} wstETH`,
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
  "Spend wstETH from yield to an address",
  {
    to: z.string().describe("Recipient address"),
    amount: z.string().describe('Amount of wstETH to spend (e.g. "0.001")'),
  },
  async ({ to, amount }) => {
    try {
      if (!ethers.isAddress(to)) {
        throw new Error(`Invalid recipient address: ${to}`);
      }

      const amountWei = ethers.parseEther(amount);
      if (amountWei <= 0n) {
        throw new Error("Amount must be greater than zero");
      }

      const vault = getVault(getSigner());
      const tx = await vault.spend(to, amountWei);
      const receipt = await tx.wait();

      const text = [
        `Spend successful!`,
        `To:      ${to}`,
        `Amount:  ${amount} wstETH`,
        `Tx Hash: ${receipt.hash}`,
      ].join("\n");

      return { content: [{ type: "text", text }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error spending yield: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// ---- spend_and_swap ----
server.tool(
  "spend_and_swap",
  "Swap yield wstETH to another token via Uniswap and send to an address",
  {
    token_out: z.string().describe("Address of the token to receive"),
    amount: z.string().describe('Amount of wstETH to swap (e.g. "0.01")'),
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
          if (parsed && parsed.name === "YieldSwapped") {
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
        vault.queryFilter("YieldWithdrawn", fromBlock, currentBlock),
        vault.queryFilter("YieldSwapped", fromBlock, currentBlock),
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
