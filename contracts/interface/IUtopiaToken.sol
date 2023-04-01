// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";


interface IUtopiaToken is IERC20MetadataUpgradeable {
    function mint(address _account, uint256 _amount) external;
    function burn(address _account, uint256 _amount) external;
}