// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;



interface IInviteManager {
    function tryInvite(address _inviter, address _invitee) external returns (bool);
    function inviteRateOfNftSell() external returns (uint256);
    function inviters(address _b) external returns (address);
}
