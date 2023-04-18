// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct FeeInfo {
    uint256 _openPositionFeeRate; // ?/10000
    uint256 _closePositionFeeRate; // ?/10000
    uint256 _pointDiff; // ?/10000
    uint256 _rolloverFeePerSecond; // ?/(10 ** 10) per second
    uint256 _fundingFeePerSecond; //  ?/(10 ** 10) per second
    int256 _accuFundingFeePerOiLong; // ?/(10 ** 18)
    int256 _accuFundingFeePerOiShort; // ?/(10 ** 18)
    uint256 _lastAccuFundingFeeTime;
}

struct SupportTokenInfo {
    bool _enabled;
    address _collateralToken;
    uint256 _collateralRate; // ?/10000
    uint256 _longFactor1; // a1 * k1 / P1 + ... + an * kn / Pn
    uint256 _longPosSizeTotal; // A1+A2+.._An
    uint256 _shortFactor1; // a1 * k1 / P1 + ... + an * kn / Pn
    uint256 _shortPosSizeTotal; // A1+A2+.._An
    int256 _realizedTradeProfit; // realized profit of _collateralToken. totalFloat = totalLongFloat + totalShortFloat - _realizedTradeProfit
    uint256 _minPositionSize;
    uint256 _maxPositionSize;
    uint256 _upsMaxPositionSizeRate; // ?/10000
    uint256 _leverage1; // first position's leverage
    FeeInfo _feeInfo;
}

interface IRouter {
    function totalLongFloat() external view returns (int256[] memory);
    function totalShortFloat() external view returns (int256[] memory);
    function totalFloat() external view returns (int256);
    function supportTokens(uint256 _index) external view returns (address);
}
