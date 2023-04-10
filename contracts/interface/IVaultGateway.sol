// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUtopiaToken} from "../interface/IUtopiaToken.sol";

interface IVaultGateway {
    function utopiaToken() external view returns (IUtopiaToken);

    function utopiaTokenPrice() external view returns (uint256);

    function sendProfit(address _account, address _token, uint256 _amount) external;

    function receiveLoss(address _token, uint256 _amount) external;

    function reserveTotal() external view returns (uint256);
}
