"""VaultClient -- Python SDK for interacting with AgentVault contracts."""

from __future__ import annotations

from typing import Any

from web3 import Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError
from eth_account import Account
from eth_account.signers.local import LocalAccount

from .abi import AGENT_VAULT_ABI, AGENT_VAULT_FACTORY_ABI


# ---------------------------------------------------------------------------
# Custom Exceptions
# ---------------------------------------------------------------------------

class YieldVaultError(Exception):
    """Base exception for all AgentVault SDK errors."""


class InsufficientYieldError(YieldVaultError):
    """Raised when trying to spend more than available budget."""


class ExceedsDailyLimitError(YieldVaultError):
    """Raised when a spend would exceed the daily budget."""


class ExceedsPerTxLimitError(YieldVaultError):
    """Raised when a single spend exceeds the per-transaction cap."""


class VaultPausedError(YieldVaultError):
    """Raised when the vault is paused."""


class NotAuthorizedError(YieldVaultError):
    """Raised when the caller is not the agent (or owner, as applicable)."""


class TransactionFailedError(YieldVaultError):
    """Raised when a transaction reverts or cannot be sent."""


_ERROR_MAP: dict[str, type[YieldVaultError]] = {
    "ExceedsBudget": InsufficientYieldError,
    "ExceedsDailyLimit": ExceedsDailyLimitError,
    "ExceedsPerTxLimit": ExceedsPerTxLimitError,
    "VaultPaused": VaultPausedError,
    "OnlyAgent": NotAuthorizedError,
    "OnlyOwner": NotAuthorizedError,
}


def _translate_revert(err: Exception) -> YieldVaultError:
    msg = str(err)
    for selector, exc_cls in _ERROR_MAP.items():
        if selector in msg:
            return exc_cls(msg)
    return TransactionFailedError(msg)


def _build_tx(w3: Web3, address: str, fn, gas: int = 300_000) -> dict:
    return fn.build_transaction({
        "from": address,
        "nonce": w3.eth.get_transaction_count(address),
        "gas": gas,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.1, "gwei"),
    })


def _send_tx(w3: Web3, account: LocalAccount, tx: dict) -> str:
    signed = account.sign_transaction(tx)
    try:
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    except Exception as exc:
        raise TransactionFailedError(f"send_raw_transaction failed: {exc}") from exc
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt.status != 1:
        raise TransactionFailedError(f"Transaction reverted (tx_hash={tx_hash.hex()})")
    return tx_hash.hex()


# ---------------------------------------------------------------------------
# VaultClient
# ---------------------------------------------------------------------------

class VaultClient:
    """High-level client for an AI agent to interact with an AgentVault.

    Parameters
    ----------
    rpc_url : str
        JSON-RPC endpoint.
    vault_address : str
        Address of the deployed AgentVault contract.
    agent_private_key : str
        Hex-encoded private key of the agent wallet.
    """

    def __init__(self, rpc_url: str, vault_address: str, agent_private_key: str) -> None:
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        if not self.w3.is_connected():
            raise YieldVaultError(f"Cannot connect to RPC at {rpc_url}")

        self.account: LocalAccount = Account.from_key(agent_private_key)
        self.address: str = self.account.address

        self.vault: Contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(vault_address),
            abi=AGENT_VAULT_ABI,
        )

    def check_budget(self, token_address: str) -> dict[str, int]:
        """Return the current budget snapshot for a specific token.

        Parameters
        ----------
        token_address : str
            Address of the ERC-20 token to query.

        Returns
        -------
        dict with keys: balance, daily_remaining, daily_limit, per_tx_limit
        """
        token = Web3.to_checksum_address(token_address)
        try:
            balance = self.vault.functions.balanceOf(token).call()
            daily_remaining = self.vault.functions.remainingDailyBudget(token).call()
            daily_limit = self.vault.functions.effectiveDailyLimit(token).call()
            per_tx_limit = self.vault.functions.effectivePerTxLimit(token).call()
        except ContractLogicError as exc:
            raise _translate_revert(exc) from exc

        return {
            "balance": balance,
            "daily_remaining": daily_remaining,
            "daily_limit": daily_limit,
            "per_tx_limit": per_tx_limit,
        }

    def spend(self, token_address: str, to_address: str, amount_wei: int, reason: str) -> str:
        """Spend tokens from the vault.

        Parameters
        ----------
        token_address : str
            Address of the ERC-20 token to spend.
        to_address : str
            Recipient address.
        amount_wei : int
            Amount in token's smallest unit.
        reason : str
            Why the agent is spending (stored on-chain). Must be non-empty.

        Returns
        -------
        str
            Transaction hash (hex).
        """
        if not reason:
            raise YieldVaultError("Reason is required and must be non-empty")
        token = Web3.to_checksum_address(token_address)
        to_address = Web3.to_checksum_address(to_address)
        try:
            fn = self.vault.functions.spend(token, to_address, amount_wei, reason)
            tx = _build_tx(self.w3, self.address, fn)
        except ContractLogicError as exc:
            raise _translate_revert(exc) from exc
        return _send_tx(self.w3, self.account, tx)

    def get_tokens(self) -> list[str]:
        """Return list of all supported token addresses in the vault."""
        return self.vault.functions.getTokens().call()

    def get_history(self, from_block: int = 0) -> list[dict[str, Any]]:
        """Fetch all AgentSpent events.

        The AgentSpent event has 3 indexed params: agent, token, to.
        """
        try:
            events = self.vault.events.AgentSpent.get_logs(from_block=from_block)
        except Exception as exc:
            raise YieldVaultError(f"Failed to fetch events: {exc}") from exc

        results: list[dict[str, Any]] = []
        for entry in events:
            results.append({
                "agent": entry.args.agent,
                "token": entry.args.token,
                "to": entry.args.to,
                "amount": entry.args.amount,
                "reason": entry.args.reason,
                "block_number": entry.blockNumber,
                "tx_hash": entry.transactionHash.hex(),
            })
        return results

    def get_staking_info(self) -> dict[str, Any]:
        """Return staking-related information.

        Returns
        -------
        dict with keys: staked_principal, pending_yield, spendable_yield, yield_only
        """
        try:
            staked = self.vault.functions.stakedPrincipal().call()
            pending = self.vault.functions.pendingYield().call()
            spendable = self.vault.functions.spendableYield().call()
            yield_only = self.vault.functions.yieldOnly().call()
        except ContractLogicError as exc:
            raise _translate_revert(exc) from exc

        return {
            "staked_principal": staked,
            "pending_yield": pending,
            "spendable_yield": spendable,
            "yield_only": yield_only,
        }

    # Properties
    @property
    def is_paused(self) -> bool:
        return self.vault.functions.paused().call()

    @property
    def vault_owner(self) -> str:
        return self.vault.functions.owner().call()

    @property
    def vault_agent(self) -> str:
        return self.vault.functions.agent().call()


# ---------------------------------------------------------------------------
# FactoryClient
# ---------------------------------------------------------------------------

class FactoryClient:
    """Read-only client for querying the AgentVaultFactory."""

    def __init__(self, rpc_url: str, factory_address: str) -> None:
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.factory: Contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(factory_address),
            abi=AGENT_VAULT_FACTORY_ABI,
        )

    def total_vaults(self) -> int:
        return self.factory.functions.totalVaults().call()

    def get_vaults_by_owner(self, owner: str) -> list[str]:
        return self.factory.functions.getVaultsByOwner(
            Web3.to_checksum_address(owner)
        ).call()

    def get_vaults_by_agent(self, agent: str) -> list[str]:
        return self.factory.functions.getVaultsByAgent(
            Web3.to_checksum_address(agent)
        ).call()
