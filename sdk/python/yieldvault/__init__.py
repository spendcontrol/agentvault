"""YieldVault Python SDK -- let any AI agent operate a YieldVault treasury."""

from .vault import (
    VaultClient,
    FactoryClient,
    YieldVaultError,
    InsufficientYieldError,
    ExceedsDailyLimitError,
    ExceedsPerTxLimitError,
    VaultPausedError,
    NotAuthorizedError,
    TransactionFailedError,
)

__all__ = [
    "VaultClient",
    "FactoryClient",
    "YieldVaultError",
    "InsufficientYieldError",
    "ExceedsDailyLimitError",
    "ExceedsPerTxLimitError",
    "VaultPausedError",
    "NotAuthorizedError",
    "TransactionFailedError",
]

__version__ = "0.1.0"
