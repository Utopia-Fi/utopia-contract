// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract UpsToken is ERC20Upgradeable, OwnableUpgradeable {
    address public vaultGateway;

    function initialize(
        string memory _name,
        string memory _symbol,
        address _vaultGateway
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ERC20Upgradeable.__ERC20_init(_name, _symbol);
        vaultGateway = _vaultGateway;
    }

    function changeVaultGateway(address _vaultGateway) external onlyOwner {
        vaultGateway = _vaultGateway;
    }

    modifier onlyVaultGateway() {
        require(
            msg.sender == vaultGateway,
            "UpsToken::onlyVaultGateway: not vaultGateway"
        );
        _;
    }

    function mint(address _account, uint256 _amount) external onlyVaultGateway {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyVaultGateway {
        _burn(_account, _amount);
    }
}
