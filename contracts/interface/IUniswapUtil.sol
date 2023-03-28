// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface IUniswapUtil {
    function swapExactInput(
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        address _tokenIn,
        address _tokenOut,
        uint256 _poolFee
    ) external payable returns (uint256 _amountOut);

    function swapExactOutput(
        uint256 _amountOut,
        uint256 _amountInMaximum,
        address _tokenIn,
        address _tokenOut,
        uint256 _poolFee
    ) external returns (uint256 _amountIn);
}