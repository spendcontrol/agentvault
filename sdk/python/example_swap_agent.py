#!/usr/bin/env python3
"""Example agent that swaps yield wstETH → USDC via Uniswap.

Demonstrates the full flow:
  1. Check available yield in the vault
  2. Swap wstETH → USDC via Uniswap V3
  3. Use USDC to pay for services (API calls, compute, etc.)

Configure via environment variables:
  RPC_URL            - JSON-RPC endpoint
  VAULT_ADDRESS      - Deployed YieldVault contract address
  AGENT_PRIVATE_KEY  - Agent wallet private key
  USDC_ADDRESS       - USDC token address on the target chain
  UNISWAP_FEE        - Pool fee tier (default: 3000 = 0.3%)
  SPEND_THRESHOLD    - Min yield (wei) before swapping (default: 1e15)
  SWAP_AMOUNT        - wstETH amount (wei) to swap each cycle (default: 5e14)
"""

from __future__ import annotations

import os
import sys
import time

from yieldvault import VaultClient, YieldVaultError


def main() -> None:
    rpc_url = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
    vault_address = os.environ.get("VAULT_ADDRESS", "")
    agent_key = os.environ.get("AGENT_PRIVATE_KEY", "")
    usdc_address = os.environ.get("USDC_ADDRESS", "")
    fee = int(os.environ.get("UNISWAP_FEE", "3000"))
    spend_threshold = int(float(os.environ.get("SPEND_THRESHOLD", str(int(1e15)))))
    swap_amount = int(float(os.environ.get("SWAP_AMOUNT", str(int(5e14)))))
    loop_interval = int(os.environ.get("LOOP_INTERVAL", "60"))

    if not all([vault_address, agent_key, usdc_address]):
        print("ERROR: VAULT_ADDRESS, AGENT_PRIVATE_KEY, and USDC_ADDRESS required.", file=sys.stderr)
        sys.exit(1)

    client = VaultClient(rpc_url, vault_address, agent_key)
    print(f"[init] Agent: {client.address}")
    print(f"[init] Vault: {client.vault.address}")
    print(f"[init] USDC:  {usdc_address}")
    print(f"[init] Swap:  {swap_amount} wei wstETH → USDC (fee: {fee})")
    print()

    cycle = 0
    while True:
        cycle += 1
        print(f"--- Cycle {cycle} ---")

        try:
            budget = client.check_budget()
        except YieldVaultError as exc:
            print(f"[error] {exc}")
            time.sleep(loop_interval)
            continue

        avail = budget["available_yield"]
        print(f"[budget] yield: {avail} wei | daily left: {budget['daily_remaining']} wei")

        if avail < spend_threshold:
            print(f"[skip] Yield too low ({avail} < {spend_threshold})")
        else:
            print(f"[swap] Swapping {swap_amount} wei wstETH → USDC...")
            try:
                tx_hash = client.spend_and_swap(
                    token_out=usdc_address,
                    fee=fee,
                    amount_in_wei=swap_amount,
                    amount_out_minimum=0,  # In production, use a price oracle!
                    to_address=client.address,  # Agent receives USDC
                )
                print(f"[swap] Done! tx: {tx_hash}")

                # Now agent has USDC — can pay for APIs, compute, etc.
                print(f"[pay] Agent now has USDC to pay for services")

            except YieldVaultError as exc:
                print(f"[error] Swap failed: {exc}")

        print()
        time.sleep(loop_interval)


if __name__ == "__main__":
    main()
