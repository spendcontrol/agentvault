// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ISwapRouter} from "../../src/YieldVault.sol";

/// @title MockSwapRouter — Simulates Uniswap V3 SwapRouter for testing
/// @notice Takes tokenIn from caller, mints tokenOut to recipient at a fixed rate
contract MockSwapRouter {
    // Fixed exchange rate: 1 wstETH = mockRate tokenOut (in tokenOut decimals)
    uint256 public mockRate;
    address public tokenOut;

    constructor(uint256 _mockRate, address _tokenOut) {
        mockRate = _mockRate;
        tokenOut = _tokenOut;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        // Pull tokenIn from caller
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output
        amountOut = params.amountIn * mockRate / 1e18;

        require(amountOut >= params.amountOutMinimum, "Too little received");

        // Transfer tokenOut to recipient (must be pre-funded)
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}
