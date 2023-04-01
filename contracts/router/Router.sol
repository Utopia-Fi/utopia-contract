// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracleGetter} from "../interface/IPriceOracleGetter.sol";
import {IUtopiaToken} from "../interface/IUtopiaToken.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IWeth} from "../interface/IWeth.sol";
import {IRouter} from "../interface/IRouter.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

struct SupportTokenInfo {
    bool _enabled;
    address _collateralToken;
    uint256 _collateralRate; // ?/10000
    uint256 _longFactor1; // A1 / P1 + ... + An / Pn
    uint256 _longPosSizeTotal; // A1+A2+..+An
    uint256 _shortFactor1; // A1 / P1 + ... + An / Pn
    uint256 _shortPosSizeTotal; // A1+A2+.._An
    uint256 _rolloverFeePerBlock;
    uint256 _openPositionFeeRate; // ?/10000
    uint256 _minPositionSize;
    uint256 _maxPositionSize;
}

struct Position {
    uint256 _openPrice;
    address _collateralToken;
    uint256 _collateralAmount; // amount of collateral
    uint256 _positionSize; // _collateralAmount * leverage
    bool _isLong;
}

// BTC/USD or ETH/USD or ... Router
contract Router is OwnableUpgradeable, ReentrancyGuardUpgradeable, IRouter {
    event IncreasePosition(
        address _user,
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong
    );

    event DecreasePosition(
        address _user,
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong
    );

    address[] public supportTokens;
    mapping(address => SupportTokenInfo) public supportTokenInfos; // _collateralToken => SupportTokenInfo

    IPriceOracleGetter public priceOracle;
    address public tradePairToken; // BTC/ETH/...

    mapping(address => mapping(address => Position)) public positions; // user => (_collateralToken => Position)
    IVaultGateway public vaultGateway;
    address public weth;
    address public foundation;
    uint256 public constant FACTOR_MULTIPLIER = 10 ** 18;

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "VaultGateway::onlyEOA:: not eoa");
        _;
    }

    function initialize(
        address _priceOracle,
        address _tradePairToken,
        address _vaultGateway,
        address _weth,
        address _foundation,
        SupportTokenInfo[] memory _supportTokenInfos
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracleGetter(_priceOracle);
        tradePairToken = _tradePairToken;
        vaultGateway = IVaultGateway(_vaultGateway);
        weth = _weth;
        foundation = _foundation;
        for (uint256 i = 0; i < _supportTokenInfos.length; i++) {
            supportTokenInfos[
                _supportTokenInfos[i]._collateralToken
            ] = _supportTokenInfos[i];
            supportTokens.push(_supportTokenInfos[i]._collateralToken);
        }
    }

    // long float usd amount
    function totalLongFloat() public view returns (int256) {
        int256 result;
        for (uint256 i = 0; i < supportTokens.length; i++) {
            SupportTokenInfo memory _supportTokenInfo = supportTokenInfos[
                supportTokens[i]
            ];
            uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
                tradePairToken
            );
            require(
                _tradePairTokenPrice > 0,
                "Router::totalLongFloat: bad _tradePairTokenPrice price"
            );
            uint256 _a = _tradePairTokenPrice * _supportTokenInfo._longFactor1;
            uint256 _b = _supportTokenInfo._longPosSizeTotal;
            if (_a >= _b) {
                result = result + int256(_a - _b);
            } else {
                result = result - int256(_b - _a);
            }
        }
        return result;
    }

    // short float usd amount
    function totalShortFloat() public view returns (int256) {
        int256 result;
        for (uint256 i = 0; i < supportTokens.length; i++) {
            SupportTokenInfo memory _supportTokenInfo = supportTokenInfos[
                supportTokens[i]
            ];
            uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
                tradePairToken
            );
            require(
                _tradePairTokenPrice > 0,
                "Router::totalShortFloat: bad _tradePairTokenPrice price"
            );
            uint256 _a = _tradePairTokenPrice * _supportTokenInfo._shortFactor1;
            uint256 _b = _supportTokenInfo._shortPosSizeTotal;
            if (_a >= _b) {
                result = result + int256(_a - _b);
            } else {
                result = result - int256(_b - _a);
            }
        }
        return result;
    }

    // float usd amount
    function totalFloat() external view returns (int256) {
        return totalLongFloat() + totalShortFloat();
    }

    function increasePosition(
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _minOrMaxPrice
    ) external payable onlyEOA nonReentrant {
        // check _collateralToken
        require(
            supportTokenInfos[_collateralToken]._enabled,
            "Router::increasePosition: not support this token"
        );
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::increasePosition: bad _tradePairTokenPrice price"
        );

        SupportTokenInfo storage _info = supportTokenInfos[_collateralToken];
        // transfer in _collateralToken
        SafeToken.safeTransferFrom(
            _collateralToken,
            msg.sender,
            address(this),
            _collateralTokenAmount
        );
        // check slippage and modify factors
        uint256 _positionSize = _collateralTokenAmount * _leverage;
        if (_isLong) {
            require(
                _tradePairTokenPrice <= _minOrMaxPrice,
                "Router::increasePosition: can not be larger than _minOrMaxPrice"
            );
            _info._longFactor1 =
                _info._longFactor1 +
                (_positionSize * (10 ** 8) * FACTOR_MULTIPLIER) /
                (_tradePairTokenPrice *
                    (10 **
                        IERC20MetadataUpgradeable(_collateralToken)
                            .decimals()));
            _info._longPosSizeTotal =
                _info._longPosSizeTotal +
                _positionSize *
                FACTOR_MULTIPLIER;
        } else {
            require(
                _tradePairTokenPrice >= _minOrMaxPrice,
                "Router::increasePosition: must be larger than _minOrMaxPrice"
            );
            _info._shortFactor1 =
                _info._shortFactor1 +
                (_positionSize * (10 ** 8) * FACTOR_MULTIPLIER) /
                (_tradePairTokenPrice *
                    (10 **
                        IERC20MetadataUpgradeable(_collateralToken)
                            .decimals()));
            _info._shortPosSizeTotal =
                _info._shortPosSizeTotal +
                _positionSize *
                FACTOR_MULTIPLIER;
        }

        // save position
        Position storage pos = positions[msg.sender][_collateralToken];
        if (pos._positionSize == 0) {
            pos._openPrice = _tradePairTokenPrice;
            pos._collateralToken = _collateralToken;
            pos._collateralAmount = _collateralTokenAmount;
            pos._positionSize = _positionSize;
            pos._isLong = _isLong;
        } else {
            // check direction
            require(
                pos._isLong == _isLong,
                "Router::increasePosition: should not increase position"
            );
            // combine pos
            pos._openPrice =
                (pos._openPrice *
                    _tradePairTokenPrice *
                    (pos._positionSize + _positionSize)) /
                (pos._openPrice *
                    _positionSize +
                    _tradePairTokenPrice *
                    pos._positionSize);
            pos._positionSize = pos._positionSize + _positionSize;
            pos._collateralAmount =
                pos._collateralAmount +
                _collateralTokenAmount;
        }
        emit IncreasePosition(
            msg.sender,
            _collateralToken,
            _collateralTokenAmount,
            _leverage,
            _isLong
        );
    }

    function decreasePosition(
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _minOrMaxPrice
    ) external payable onlyEOA nonReentrant {
        // check _collateralToken
        require(
            supportTokenInfos[_collateralToken]._enabled,
            "Router::decreasePosition: not support this token"
        );

        SupportTokenInfo storage _info = supportTokenInfos[_collateralToken];
        // transfer in _collateralToken
        SafeToken.safeTransferFrom(
            _collateralToken,
            msg.sender,
            address(this),
            _collateralTokenAmount
        );
        // check slippage and modify factors
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::decreasePosition: bad _tradePairTokenPrice price"
        );
        uint256 _positionSize = _collateralTokenAmount * _leverage;
        if (_isLong) {
            require(
                _tradePairTokenPrice <= _minOrMaxPrice,
                "Router::decreasePosition: can not be larger than _minOrMaxPrice"
            );
            _info._longFactor1 =
                _info._longFactor1 +
                (_positionSize * (10 ** 8) * FACTOR_MULTIPLIER) /
                (_tradePairTokenPrice *
                    (10 **
                        IERC20MetadataUpgradeable(_collateralToken)
                            .decimals()));
            _info._longPosSizeTotal =
                _info._longPosSizeTotal +
                _positionSize *
                FACTOR_MULTIPLIER;
        } else {
            require(
                _tradePairTokenPrice >= _minOrMaxPrice,
                "Router::decreasePosition: must be larger than _minOrMaxPrice"
            );
            _info._shortFactor1 =
                _info._shortFactor1 +
                (_positionSize * (10 ** 8) * FACTOR_MULTIPLIER) /
                (_tradePairTokenPrice *
                    (10 **
                        IERC20MetadataUpgradeable(_collateralToken)
                            .decimals()));
            _info._shortPosSizeTotal =
                _info._shortPosSizeTotal +
                _positionSize *
                FACTOR_MULTIPLIER;
        }

        // save position
        Position storage pos = positions[msg.sender][_collateralToken];
        require(
            pos._collateralAmount > 0,
            "Router::decreasePosition: bad _collateralAmount"
        );
        // check direction
        require(
            pos._isLong == !_isLong,
            "Router::decreasePosition: should not decrease position"
        );
        // close part of pos and update pos
        bool _isReverse = _positionSize >= pos._positionSize;
        if (_isReverse) {
            uint256 _remainCollateralAmount = _closePosition(_collateralToken, _positionSize - pos._positionSize, _tradePairTokenPrice);
            pos._collateralAmount = _remainCollateralAmount;
            pos._openPrice = _tradePairTokenPrice;
            pos._positionSize = _positionSize - pos._positionSize;
            pos._isLong = _isLong;
        } else {
            uint256 _remainCollateralAmount = _closePosition(_collateralToken, pos._positionSize - _positionSize, _tradePairTokenPrice);
            pos._collateralAmount = _remainCollateralAmount;
            pos._positionSize = pos._positionSize - _positionSize;
        }
        emit DecreasePosition(
            msg.sender,
            _collateralToken,
            _collateralTokenAmount,
            _leverage,
            _isLong
        );
    }

    function _closePosition(
        address _collateralToken,
        uint256 _needClosePositionSize,
        uint256 _tradePairTokenPrice
    ) private returns (uint256) {
        Position storage pos = positions[msg.sender][_collateralToken];
        require(
            pos._positionSize >= _needClosePositionSize,
            "Router::_closePosition: target position size nou enough"
        );

        uint256 _needPoccessCollateralTokenAmount = (_needClosePositionSize *
            pos._collateralAmount) / pos._positionSize;

        int256 _profit = 0;
        if (pos._isLong) {
            _profit =
                int256(
                    (_tradePairTokenPrice * _needPoccessCollateralTokenAmount) /
                        pos._openPrice
                ) -
                int256(_needPoccessCollateralTokenAmount);
        } else {
            _profit =
                int256(_needPoccessCollateralTokenAmount) -
                int256(
                    (_tradePairTokenPrice * _needPoccessCollateralTokenAmount) /
                        pos._openPrice
                );
        }

        if (_profit >= 0) {
            SafeToken.safeTransfer(
                pos._collateralToken,
                msg.sender,
                _needPoccessCollateralTokenAmount
            );
            vaultGateway.sendProfit(
                msg.sender,
                pos._collateralToken,
                uint256(_profit)
            );
            
        } else {
            SafeToken.safeTransfer(
                pos._collateralToken,
                msg.sender,
                _needPoccessCollateralTokenAmount - uint256(-_profit)
            );
            vaultGateway.receiveLoss(pos._collateralToken, uint256(-_profit));
        }

        return pos._collateralAmount - _needPoccessCollateralTokenAmount;
    }
}
