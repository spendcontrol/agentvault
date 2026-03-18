#!/usr/bin/env python3
"""Example AI agent loop that uses the YieldVault Python SDK.

This script demonstrates the minimal agent pattern:
  1. Check the current budget.
  2. If available yield exceeds a threshold, spend some to a recipient.
  3. Print status.
  4. Sleep and repeat.

Configure via environment variables:
  RPC_URL            - JSON-RPC endpoint (e.g. https://mainnet.base.org)
  VAULT_ADDRESS      - Deployed YieldVault contract address
  AGENT_PRIVATE_KEY  - Hex private key of the agent wallet
  RECIPIENT_ADDRESS  - Where to send yield (defaults to a burn address)
  SPEND_THRESHOLD    - Min available yield (wei) before spending (default 1e15)
  SPEND_AMOUNT       - Amount (wei) to spend each cycle (default 5e14)
  LOOP_INTERVAL      - Seconds between cycles (default 60)
"""

from __future__ import annotations

import os
import sys
import time

from yieldvault import (
    VaultClient,
    YieldVaultError,
    InsufficientYieldError,
    VaultPausedError,
)


def main() -> None:
    # ---- Configuration from env ----
    rpc_url = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
    vault_address = os.environ.get("VAULT_ADDRESS", "")
    agent_key = os.environ.get("AGENT_PRIVATE_KEY", "")
    recipient = os.environ.get(
        "RECIPIENT_ADDRESS",
        "0x000000000000000000000000000000000000dEaD",
    )
    spend_threshold = int(float(os.environ.get("SPEND_THRESHOLD", str(int(1e15)))))
    spend_amount = int(float(os.environ.get("SPEND_AMOUNT", str(int(5e14)))))
    loop_interval = int(os.environ.get("LOOP_INTERVAL", "60"))

    if not vault_address or not agent_key:
        print(
            "ERROR: VAULT_ADDRESS and AGENT_PRIVATE_KEY environment variables are required.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ---- Initialise client ----
    print(f"[init] Connecting to {rpc_url}")
    client = VaultClient(rpc_url, vault_address, agent_key)
    print(f"[init] Agent address: {client.address}")
    print(f"[init] Vault address: {client.vault.address}")
    print(f"[init] Spend threshold: {spend_threshold} wei")
    print(f"[init] Spend amount:    {spend_amount} wei")
    print(f"[init] Recipient:       {recipient}")
    print()

    # ---- Agent loop ----
    cycle = 0
    while True:
        cycle += 1
        print(f"--- Cycle {cycle} ---")

        try:
            budget = client.check_budget()
        except YieldVaultError as exc:
            print(f"[budget] Failed to read budget: {exc}")
            time.sleep(loop_interval)
            continue

        avail = budget["available_yield"]
        daily_rem = budget["daily_remaining"]
        principal = budget["principal"]
        total_bal = budget["total_balance"]

        print(f"[budget] principal:        {principal} wei")
        print(f"[budget] total_balance:    {total_bal} wei")
        print(f"[budget] available_yield:  {avail} wei")
        print(f"[budget] daily_remaining:  {daily_rem} wei")

        if avail < spend_threshold:
            print(f"[skip]   Yield ({avail}) below threshold ({spend_threshold}). Waiting.")
        elif daily_rem < spend_amount:
            print(f"[skip]   Daily remaining ({daily_rem}) too low for spend ({spend_amount}). Waiting.")
        else:
            print(f"[spend]  Sending {spend_amount} wei to {recipient} ...")
            try:
                tx_hash = client.spend(recipient, spend_amount)
                print(f"[spend]  Success! tx_hash={tx_hash}")
            except InsufficientYieldError:
                print("[spend]  Reverted: insufficient yield.")
            except VaultPausedError:
                print("[spend]  Reverted: vault is paused.")
            except YieldVaultError as exc:
                print(f"[spend]  Error: {exc}")

        # Show recent history
        try:
            history = client.get_history()
            print(f"[history] Total YieldWithdrawn events: {len(history)}")
            if history:
                last = history[-1]
                print(
                    f"[history] Last spend: {last['amount']} wei "
                    f"-> {last['to']} (block {last['block_number']})"
                )
        except YieldVaultError as exc:
            print(f"[history] Could not fetch history: {exc}")

        print()
        time.sleep(loop_interval)


if __name__ == "__main__":
    main()
