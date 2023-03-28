// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;



interface IRouter {
    function totalLongFloat() external view returns (uint256, bool);
    function totalShortFloat() external view returns (uint256, bool);
}
