// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;



interface IFeeReceiver {
    function receiveFee(address _token, uint256 _amount) external;
    function sendFee(address _token, address _target, uint256 _amount) external;
}
