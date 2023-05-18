// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface ISyncSwapPool {
    function getReserves() external view returns (uint _reserve0, uint _reserve1);
    function getAmountOut(address _tokenIn, uint _amountIn, address _sender) external view returns (uint _amountOut);
    function totalSupply() external view returns (uint256);
}
