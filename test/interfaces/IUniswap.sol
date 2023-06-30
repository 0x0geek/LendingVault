// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUniswapRouter {
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}
