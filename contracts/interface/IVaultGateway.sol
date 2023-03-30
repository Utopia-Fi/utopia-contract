// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct SupportTokensToOpenInfo {
    address _token;
    uint256 _collateralRate; // ?/10000
}

interface IVaultGateway {
    function platformTokenPrice() external view returns (uint256);

    function mintPlatformToken(address _account, uint256 _amount) external;

    function receiveLoss(address _token, uint256 _amount) external;

    function platformTokenTotal() external view returns (uint256);

    function reserveTotal() external view returns (uint256);

    function supportTokensToOpen(
        address _token
    ) external view returns (SupportTokensToOpenInfo memory);
}
