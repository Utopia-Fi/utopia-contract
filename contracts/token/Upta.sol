// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract UpsaToken is ERC20Upgradeable, OwnableUpgradeable {
    address public utopiaNft;

    function initialize(
        string memory _name,
        string memory _symbol,
        address _utopiaNft
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ERC20Upgradeable.__ERC20_init(_name, _symbol);
        utopiaNft = _utopiaNft;
    }

    modifier onlyUtopiaNft() {
        require(
            msg.sender == utopiaNft,
            "UpsaToken::onlyUtopiaNft: not utopiaNft"
        );
        _;
    }

    function mintTo(address[] memory _addrs, uint256[] memory _amounts) external onlyOwner {
        require(_addrs.length <= 20, "UpsaToken::mintTo: addresses too much");
        require(_addrs.length == _amounts.length, "UpsaToken::mintTo: length not equal");
        for (uint256 i = 0; i < _addrs.length; i++) {
            _mint(_addrs[i], _amounts[i]);
        }
    }

    function mint(address _account, uint256 _amount) external onlyUtopiaNft {
        _mint(_account, _amount);
    }
}
