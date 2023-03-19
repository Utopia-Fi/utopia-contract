// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracleGetter} from "../interface/IPriceOracleGetter.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract VaultGateway is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    IPriceOracleGetter public priceOracle;

    modifier onlyEOA() {
        require(
            msg.sender == tx.origin,
            "VaultGateway::onlyEOA:: not eoa"
        );
        _;
    }

    function initialize(address _priceOracle) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        
        priceOracle = IPriceOracleGetter(_priceOracle);

    }

    function mintByNft () external onlyEOA nonReentrant {
        
    }

    function redeem () external onlyEOA nonReentrant {

    }
}
