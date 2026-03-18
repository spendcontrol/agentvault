"""VaultClient -- Python SDK for interacting with YieldVault contracts."""

from __future__ import annotations

from typing import Any

from web3 import Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError
from eth_account import Account
from eth_account.signers.local import LocalAccount

from .abi import YIELD_VAULT_ABI, YIELD_VAULT_FACTORY_ABI


# ---------------------------------------------------------------------------
# Custom Exceptions
# ---------------------------------------------------------------------------

class YieldVaultError(Exception):
    """Base exception for all YieldVault SDK errors."""


class InsufficientYieldError(YieldVaultError):
    """Raised when trying to spend more than available yield."""


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


# Maps Solidity custom-error selectors to Python exceptions.
_ERROR_MAP: dict[str, type[YieldVaultError]] = {
    "ExceedsYield": InsufficientYieldError,
    "ExceedsDailyLimit": ExceedsDailyLimitError,
    "ExceedsPerTxLimit": ExceedsPerTxLimitError,
    "VaultPaused": VaultPausedError,
    "OnlyAgent": NotAuthorizedError,
    "OnlyOwner": NotAuthorizedError,
    "OnlyOwnerOrAgent": NotAuthorizedError,
}


def _translate_revert(err: Exception) -> YieldVaultError:
    """Try to match a ContractLogicError message to a typed exception."""
    msg = str(err)
    for selector, exc_cls in _ERROR_MAP.items():
        if selector in msg:
            return exc_cls(msg)
    return TransactionFailedError(msg)


# ---------------------------------------------------------------------------
# VaultClient
# ---------------------------------------------------------------------------

class VaultClient:
    """High-level client for an AI agent to interact with a single YieldVault.

    Parameters
    ----------
    rpc_url : str
        JSON-RPC endpoint (e.g. ``https://mainnet.base.org``).
    vault_address : str
        Address of the deployed ``YieldVault`` contract.
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
            abi=YIELD_VAULT_ABI,
        )

    # ------------------------------------------------------------------
    # Read helpers
    # ------------------------------------------------------------------

    def check_budget(self) -> dict[str, int]:
        """Return the current budget snapshot.

        Returns
        -------
        dict
            Keys: ``available_yield``, ``daily_remaining``, ``principal``,
            ``total_balance``.  All values are ``int`` in wei.
        """
        try:
            stats = self.vault.functions.getStats().call()
        except ContractLogicError as exc:
            raise _translate_revert(exc) from exc

        return {
            "principal": stats[0],
            "total_balance": stats[1],
            "available_yield": stats[2],
            "total_yield_spent": stats[3],
            "daily_remaining": stats[4],
        }

    def get_stats(self) -> dict[str, int]:
        """Call ``getStats()`` and return a labelled dict.

        Returns
        -------
        dict
            Keys: ``principal``, ``current_balance``, ``available_yield``,
            ``total_yield_spent``, ``remaining_daily_budget``.
        """
        try:
            s = self.vault.functions.getStats().call()
        except ContractLogicError as exc:
            raise _translate_revert(exc) from exc

        return {
            "principal": s[0],
            "current_balance": s[1],
            "available_yield": s[2],
            "total_yield_spent": s[3],
            "remaining_daily_budget": s[4],
        }

    def get_history(self, from_block: int = 0) -> list[dict[str, Any]]:
        """Fetch all ``YieldWithdrawn`` events emitted by the vault.

        Parameters
        ----------
        from_block : int, optional
            Block number to start scanning from (default ``0``).

        Returns
        -------
        list[dict]
            Each dict contains ``agent``, ``to``, ``amount``, ``block_number``,
            and ``tx_hash``.
        """
        try:
            event_filter = self.vault.events.YieldWithdrawn.get_logs(
                from_block=from_block,
            )
        except Exception as exc:
            raise YieldVaultError(f"Failed to fetch YieldWithdrawn events: {exc}") from exc

        results: list[dict[str, Any]] = []
        for entry in event_filter:
            results.append(
                {
                    "agent": entry.args.agent,
                    "to": entry.args.to,
                    "amount": entry.args.amount,
                    "block_number": entry.blockNumber,
                    "tx_hash": entry.transactionHash.hex(),
                }
            )
        return results

    # ------------------------------------------------------------------
    # Write helpers
    # ------------------------------------------------------------------

    def spend(self, to_address: str, amount_wei: int) -> str:
        """Spend available yield by sending wstETH to *to_address*.

        Parameters
        ----------
        to_address : str
            Recipient address.
        amount_wei : int
            Amount of wstETH in wei to transfer.

        Returns
        -------
        str
            Transaction hash (hex).

        Raises
        ------
        InsufficientYieldError
            If ``amount_wei`` exceeds available yield.
        ExceedsDailyLimitError
            If spend would exceed the daily budget.
        ExceedsPerTxLimitError
            If ``amount_wei`` exceeds the per-transaction cap.
        VaultPausedError
            If the vault is currently paused.
        NotAuthorizedError
            If the signer is not the registered agent.
        TransactionFailedError
            For any other on-chain revert.
        """
        to_address = Web3.to_checksum_address(to_address)

        try:
            tx = self.vault.functions.spend(to_address, amount_wei).build_transaction(
                {
                    "from": self.address,
                    "nonce": self.w3.eth.get_transaction_count(self.address),
                    "gas": 250_000,
                    "maxFeePerGas": self.w3.eth.gas_price * 2,
                    "maxPriorityFeePerGas": self.w3.to_wei(0.1, "gwei"),
                }
            )
        except ContractLogicError as exc:
            raise _translate_revert(exc) from exc

        signed = self.account.sign_transaction(tx)
        try:
            tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        except Exception as exc:
            raise TransactionFailedError(f"send_raw_transaction failed: {exc}") from exc

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt.status != 1:
            raise TransactionFailedError(
                f"Transaction reverted (tx_hash={tx_hash.hex()})"
            )
        return tx_hash.hex()

    # ------------------------------------------------------------------
    # Convenience properties
    # ------------------------------------------------------------------

    @property
    def is_paused(self) -> bool:
        """Return ``True`` if the vault is currently paused."""
        return self.vault.functions.paused().call()

    @property
    def daily_limit(self) -> int:
        """Return the vault's daily spend limit in wei."""
        return self.vault.functions.dailyLimit().call()

    @property
    def per_tx_limit(self) -> int:
        """Return the vault's per-transaction spend limit in wei."""
        return self.vault.functions.perTxLimit().call()

    @property
    def vault_owner(self) -> str:
        """Return the vault owner address."""
        return self.vault.functions.owner().call()

    @property
    def vault_agent(self) -> str:
        """Return the vault's registered agent address."""
        return self.vault.functions.agent().call()


# ---------------------------------------------------------------------------
# FactoryClient (bonus helper)
# ---------------------------------------------------------------------------

class FactoryClient:
    """Read-only client for querying the YieldVaultFactory."""

    def __init__(self, rpc_url: str, factory_address: str) -> None:
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.factory: Contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(factory_address),
            abi=YIELD_VAULT_FACTORY_ABI,
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
