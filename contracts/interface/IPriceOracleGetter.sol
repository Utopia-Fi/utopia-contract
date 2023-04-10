// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IPriceOracleGetter interface
 * @notice Interface for the Aave price oracle.
 **/

interface IPriceOracleGetter {

  function getAssetPrice(address _assetAddr) external view returns (uint256);
  function getAssetsPrices(
        address[] calldata _assetAddrs
    ) external view returns (uint256[] memory);
}
