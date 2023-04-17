// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IInviteManager} from "../interface/IInviteManager.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IRouter} from "../interface/IRouter.sol";

contract InviteManager is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IInviteManager
{
    event Invited(address indexed _inviter, address _invitee);

    mapping(address => address) public inviters; // B => A, A invited B
    uint256 public inviteRateOfNftSell;
    mapping(address => bool) public tryInviteWhiteList;
    IVaultGateway public vaultGateway;

    function initialize(
        address[] calldata _tryInviteWhiteList,
        uint256 _inviteRateOfNftSell,
        address _vaultGateway
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        for (uint256 i = 0; i < _tryInviteWhiteList.length; i++) {
            tryInviteWhiteList[_tryInviteWhiteList[i]] = true;
        }
        inviteRateOfNftSell = _inviteRateOfNftSell;
        vaultGateway = IVaultGateway(_vaultGateway);
    }

    modifier onlyTryInviteWhiteList() {
        bool _isRouter = false;
        if (address(vaultGateway) != address(0)) {
            IRouter[] memory routers = vaultGateway.listRouters();
            for (uint256 i = 0; i < routers.length; i++) {
                if (msg.sender == address(routers[i])) {
                    _isRouter = true;
                    break;
                }
            }
        }

        require(
            tryInviteWhiteList[msg.sender] || _isRouter,
            "UtopiaSloth::onlyTryInviteWhiteList: not tryInviteWhiteList"
        );
        _;
    }

    function changeVaultGateway(address _vaultGateway) external onlyOwner {
        vaultGateway = IVaultGateway(_vaultGateway);
    }

    function changeInviteRateOfNftSell(
        uint256 _inviteRateOfNftSell
    ) external onlyOwner {
        inviteRateOfNftSell = _inviteRateOfNftSell;
    }

    function changeTryInviteWhiteList(
        address[] calldata _tryInviteWhiteList
    ) external onlyOwner {
        for (uint256 i = 0; i < _tryInviteWhiteList.length; i++) {
            tryInviteWhiteList[_tryInviteWhiteList[i]] = true;
        }
    }

    function tryInvite(
        address _inviter,
        address _invitee
    ) external onlyTryInviteWhiteList returns (bool) {
        if (_inviter == address(0) || _invitee == address(0)) {
            return false;
        }
        if (
            inviters[_invitee] != address(0) && inviters[_invitee] != _inviter
        ) {
            return false;
        }
        if (inviters[_invitee] == address(0)) {
            inviters[_invitee] = _inviter;
            emit Invited(_inviter, _invitee);
        }

        return true;
    }
}
