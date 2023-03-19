// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";

// USDT Vault / USDC Vault / ...
contract Vault is OwnableUpgradeable {

    IVaultGateway public vaultGateway;

    modifier onlyVaultGateway() {
        require(
            msg.sender == address(vaultGateway),
            "Vault::onlyVaultGateway:: not vault gateway"
        );
        _;
    }

    function initialize(address _vaultGateway) external initializer {
        OwnableUpgradeable.__Ownable_init();
        
        vaultGateway = IVaultGateway(_vaultGateway);

    }

    function withdraw () external onlyVaultGateway {
        
    }
}
