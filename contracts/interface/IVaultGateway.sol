// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;



interface IVaultGateway {
    function platformTokenPrice() external view returns (uint256);
    function mintPlatformToken(address _account, uint256 _amount) external;
    function receiveLoss(address _token, uint256 _amount) external;
}
