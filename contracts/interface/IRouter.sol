// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;



interface IRouter {
    function totalLongFloat() external view returns (int256[] memory);
    function totalShortFloat() external view returns (int256[] memory);
    function totalFloat() external view returns (int256);
}
