// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IFeeReceiver} from "../interface/IFeeReceiver.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IRouter} from "../interface/IRouter.sol";
import {SafeToken} from "../util/SafeToken.sol";

contract FeeReceiver is OwnableUpgradeable, IFeeReceiver {
    IVaultGateway public vaultGateway;

    function initialize(address _vaultGateway) external initializer {
        OwnableUpgradeable.__Ownable_init();

        vaultGateway = IVaultGateway(_vaultGateway);
    }

    modifier onlyRouters() {
        bool _isRouter = false;
        IRouter[] memory routers = vaultGateway.listRouters();
        for (uint256 i = 0; i < routers.length; i++) {
            if (msg.sender == address(routers[i])) {
                _isRouter = true;
                break;
            }
        }
        require(_isRouter, "FeeReceiver::onlyRouters: not router");
        _;
    }

    function changeVaultGateway(address _vaultGateway) external onlyOwner {
        vaultGateway = IVaultGateway(_vaultGateway);
    }

    function receiveFee(address _token, uint256 _amount) external onlyRouters {
        SafeToken.safeTransferFrom(_token, msg.sender, address(this), _amount);
    }

    function sendFee(
        address _token,
        address _target,
        uint256 _amount
    ) external onlyRouters {
        SafeToken.safeTransfer(_token, _target, _amount);
    }
}
