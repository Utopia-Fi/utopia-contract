// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface IUtopiaSloth {
    function pricePer() external view returns (uint256);

    function soldAmount() external view returns (uint256);

    function maxSoldAmount() external view returns (uint256);
}
