// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface IPriceOracle {
    function getAssetPrice(address _assetAddr) external view returns (uint256);

    function getAssetsPrices(
        address[] calldata _assetAddrs
    ) external view returns (uint256[] memory);

    function feedAndCall(
        address[] calldata _assetAddrs,
        uint256[] calldata _assetPrices,
        address _callAddr,
        bytes calldata _data
    ) external;

    function getPrices(
        address _assetAddr
    ) external view returns (uint256[] memory);
}
