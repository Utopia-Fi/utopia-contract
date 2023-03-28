// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

interface IWeth is IERC20MetadataUpgradeable {
    function deposit() external payable;

    function depositTo(address account) external payable;

    function withdraw(uint256 amount) external;

    function withdrawTo(address account, uint256 amount) external;
}
