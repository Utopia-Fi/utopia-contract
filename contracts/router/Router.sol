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
    uint256 _longFactor1; // a1 * k1 / P1 + ... + an * kn / Pn
    uint256 _longPosSizeTotal; // A1+A2+.._An
    uint256 _shortFactor1; // a1 * k1 / P1 + ... + an * kn / Pn
    uint256 _shortPosSizeTotal; // A1+A2+.._An
    int256 _realizedProfit; // realized profit of _collateralToken. totalFloat = totalLongFloat + totalShortFloat - _realizedProfit
    uint256 _rolloverFeePerBlock;
    uint256 _openPositionFeeRate; // ?/10000
    uint256 _minPositionSize;
    uint256 _maxPositionSize;
    uint256 _upsMaxPositionSizeRate; // ?/10000
    uint256 _leverage1; // first position's leverage
}

struct Position {
    uint256 _openPrice;
    address _collateralToken;
    uint256 _collateralTokenAmount; // amount of collateral
    uint256 _leverage;
    uint256 _positionSize; // _collateralTokenAmount * leverage
    bool _isLong;
}

// BTC/USD or ETH/USD or ... Router
contract Router is OwnableUpgradeable, ReentrancyGuardUpgradeable, IRouter {
    event IncreasePosition(
        address _user,
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice
    );

    event DecreasePosition(
        address _user,
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice
    );

    event ClosePosition(
        address _user,
        address _collateralToken,
        uint256 _closedPositionSize,
        uint256 _tradePairTokenPrice,
        int256 _profit
    );

    address[] public supportTokens;
    mapping(address => SupportTokenInfo) public supportTokenInfos; // _collateralToken => SupportTokenInfo

    IPriceOracleGetter public priceOracle;
    address public tradePairToken; // BTC/ETH/...

    mapping(bytes32 => Position) public positions; // posId => Position
    IVaultGateway public vaultGateway;
    address public weth;
    uint256 public constant FACTOR_MULTIPLIER = 10 ** 18;
    mapping(address => bool) public liquidators;
    uint256 public maxLeverage;

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "VaultGateway::onlyEOA:: not eoa");
        _;
    }

    modifier onlyLiquidator() {
        require(
            liquidators[msg.sender],
            "VaultGateway::onlyLiquidator:: not liquidator"
        );
        _;
    }

    function initialize(
        address _priceOracle,
        address _tradePairToken,
        address _vaultGateway,
        address _weth,
        SupportTokenInfo[] memory _supportTokenInfos
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracleGetter(_priceOracle);
        tradePairToken = _tradePairToken;
        vaultGateway = IVaultGateway(_vaultGateway);
        weth = _weth;
        for (uint256 i = 0; i < _supportTokenInfos.length; i++) {
            supportTokenInfos[
                _supportTokenInfos[i]._collateralToken
            ] = _supportTokenInfos[i];
            supportTokens.push(_supportTokenInfos[i]._collateralToken);
        }
        maxLeverage = 100;
    }

    function changeMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        maxLeverage = _maxLeverage;
    }

    function getPosId(
        address _account,
        address _collateralToken
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _collateralToken));
    }

    function supportTokenAmount() external view returns (uint256) {
        return supportTokens.length;
    }

    // long float
    function totalLongFloat() public view returns (int256[] memory) {
        int256[] memory _floats = new int256[](supportTokens.length);
        for (uint256 i = 0; i < supportTokens.length; i++) {
            SupportTokenInfo memory _supportTokenInfo = supportTokenInfos[
                supportTokens[i]
            ];
            if (_supportTokenInfo._leverage1 == 0) {
                _floats[i] = 0;
                continue;
            }
            uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
                tradePairToken
            );
            require(
                _tradePairTokenPrice > 0,
                "Router::totalLongFloat: bad _tradePairTokenPrice price"
            );
            uint256 _a = (_tradePairTokenPrice *
                _supportTokenInfo._longFactor1) / _supportTokenInfo._leverage1;
            uint256 _b = _supportTokenInfo._longPosSizeTotal /
                _supportTokenInfo._leverage1;
            if (_a >= _b) {
                _floats[i] = int256(_a - _b) / int256(FACTOR_MULTIPLIER);
            } else {
                _floats[i] = -int256(_b - _a) / int256(FACTOR_MULTIPLIER);
            }
        }
        return _floats;
    }

    // short float
    function totalShortFloat() public view returns (int256[] memory) {
        int256[] memory _floats = new int256[](supportTokens.length);
        for (uint256 i = 0; i < supportTokens.length; i++) {
            SupportTokenInfo memory _supportTokenInfo = supportTokenInfos[
                supportTokens[i]
            ];
            if (_supportTokenInfo._leverage1 == 0) {
                _floats[i] = 0;
                continue;
            }
            uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
                tradePairToken
            );
            require(
                _tradePairTokenPrice > 0,
                "Router::totalShortFloat: bad _tradePairTokenPrice price"
            );
            uint256 _a = (_tradePairTokenPrice *
                _supportTokenInfo._shortFactor1) / _supportTokenInfo._leverage1;
            uint256 _b = _supportTokenInfo._shortPosSizeTotal /
                _supportTokenInfo._leverage1;
            if (_a >= _b) {
                _floats[i] = -int256(_a - _b) / int256(FACTOR_MULTIPLIER);
            } else {
                _floats[i] = int256(_b - _a) / int256(FACTOR_MULTIPLIER);
            }
        }
        return _floats;
    }

    // total float usd amount
    function totalFloat() external view returns (int256) {
        int256[] memory _totalLongFloat = totalLongFloat();
        int256[] memory _totalShortFloat = totalShortFloat();
        int256 result;
        for (uint256 i = 0; i < supportTokens.length; i++) {
            address _token = supportTokens[i];
            uint256 _tokenPrice = priceOracle.getAssetPrice(_token);
            require(
                _tokenPrice > 0,
                "Router::_tokenPrice: bad _tokenPrice price"
            );
            result =
                result +
                ((_totalLongFloat[i] +
                    _totalShortFloat[i] -
                    supportTokenInfos[_token]._realizedProfit) *
                    int256(_tokenPrice)) /
                int256(10 ** IERC20MetadataUpgradeable(_token).decimals());
        }
        return result;
    }

    function getPosProfit(
        address _collateralToken
    ) external view returns (int256) {
        Position memory _pos = positions[
            getPosId(msg.sender, _collateralToken)
        ];
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::getPosProfit: bad _tradePairTokenPrice price"
        );
        return _getPosProfit(_pos, _tradePairTokenPrice, _pos._positionSize);
    }

    function canLiquidate(
        bytes32 _posId
    ) external view onlyLiquidator returns (bool) {
        Position memory _pos = positions[_posId];
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::canLiquidate: bad _tradePairTokenPrice price"
        );
        return _canLiquidate(_pos, _tradePairTokenPrice);
    }

    function _canLiquidate(
        Position memory _pos,
        uint256 _tradePairTokenPrice
    ) private view returns (bool) {
        require(
            _pos._positionSize > 0,
            "Router::_canLiquidate: target position is null"
        );

        (int256 _profit, uint256 _net) = _posScore(_pos, _tradePairTokenPrice);
        if (_profit >= 0) {
            return false;
        }
        return uint256(-_profit) >= _net;
    }

    function posScore(
        address _collateralToken
    ) external view returns (int256, uint256) {
        Position memory _pos = positions[
            getPosId(msg.sender, _collateralToken)
        ];
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::posScore: bad _tradePairTokenPrice price"
        );
        return _posScore(_pos, _tradePairTokenPrice);
    }

    function _posScore(
        Position memory _pos,
        uint256 _tradePairTokenPrice
    ) private view returns (int256, uint256) {
        int256 _profit = _getPosProfit(
            _pos,
            _tradePairTokenPrice,
            _pos._positionSize
        );
        return (
            _profit,
            (_pos._collateralTokenAmount *
                supportTokenInfos[_pos._collateralToken]._collateralRate) /
                10000
        );
    }

    function liquidate(bytes32 _posId) external onlyLiquidator {
        Position storage _pos = positions[_posId];
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::liquidate: bad _tradePairTokenPrice price"
        );
        require(
            _canLiquidate(_pos, _tradePairTokenPrice),
            "Router::liquidate: can not liquidate"
        );

        _closePosition(_pos, _tradePairTokenPrice);
    }

    function _getPosProfit(
        Position memory _pos,
        uint256 _tradePairTokenPrice,
        uint256 _positionSize
    ) private pure returns (int256) {
        int256 _profit = 0;
        if (_pos._isLong) {
            _profit =
                int256(
                    (_tradePairTokenPrice * _positionSize) / _pos._openPrice
                ) -
                int256(_positionSize);
        } else {
            _profit =
                int256(_positionSize) -
                int256(
                    (_tradePairTokenPrice * _positionSize) / _pos._openPrice
                );
        }
        return _profit / int256(_pos._leverage);
    }

    function _changeFactors(
        SupportTokenInfo storage _info,
        bool _isLong,
        uint256 _positionSize,
        uint256 _tradePairTokenPrice
    ) private {
        if (_isLong) {
            _info._longFactor1 =
                _info._longFactor1 +
                (_positionSize * FACTOR_MULTIPLIER) /
                _tradePairTokenPrice;
            _info._longPosSizeTotal =
                _info._longPosSizeTotal +
                _positionSize *
                FACTOR_MULTIPLIER;
        } else {
            _info._shortFactor1 =
                _info._shortFactor1 +
                (_positionSize * FACTOR_MULTIPLIER) /
                _tradePairTokenPrice;
            _info._shortPosSizeTotal =
                _info._shortPosSizeTotal +
                _positionSize *
                FACTOR_MULTIPLIER;
        }
    }

    function increasePosition(
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _minOrMaxPrice
    ) external payable onlyEOA nonReentrant {
        require(
            _leverage <= maxLeverage,
            "Router::increasePosition: _leverage too large"
        );
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

        // save position
        uint256 _positionSize = _collateralTokenAmount * _leverage;
        bytes32 _posId = getPosId(msg.sender, _collateralToken);
        Position storage _pos = positions[_posId];
        if (_pos._positionSize == 0) {
            _pos._openPrice = _tradePairTokenPrice;
            _pos._collateralToken = _collateralToken;
            _pos._collateralTokenAmount = _collateralTokenAmount;
            _pos._leverage = _leverage;
            _pos._positionSize = _positionSize;
            _pos._isLong = _isLong;
            _info._leverage1 = _leverage;
        } else {
            // check direction
            require(
                _pos._isLong == _isLong,
                "Router::increasePosition: should not increase position"
            );
            // combine pos
            _pos._openPrice =
                (_pos._openPrice *
                    _tradePairTokenPrice *
                    (_pos._positionSize + _positionSize)) /
                (_pos._openPrice *
                    _positionSize +
                    _tradePairTokenPrice *
                    _pos._positionSize);
            _pos._positionSize = _pos._positionSize + _positionSize;
            _pos._collateralTokenAmount =
                _pos._collateralTokenAmount +
                _collateralTokenAmount;
        }
        require(
            !_canLiquidate(_pos, _tradePairTokenPrice),
            "Router::increasePosition: can not liquidate"
        );
        // check slippage and modify factors
        if (_isLong) {
            require(
                _tradePairTokenPrice <= _minOrMaxPrice,
                "Router::increasePosition: can not be larger than _minOrMaxPrice"
            );
        } else {
            require(
                _tradePairTokenPrice >= _minOrMaxPrice,
                "Router::increasePosition: must be larger than _minOrMaxPrice"
            );
        }
        _changeFactors(_info, _isLong, _positionSize, _tradePairTokenPrice);

        IUtopiaToken _utopiaToken = vaultGateway.utopiaToken();
        if (_pos._collateralToken == address(_utopiaToken)) {
            require(
                _pos._positionSize <=
                    _utopiaToken.totalSupply() * _info._upsMaxPositionSizeRate,
                "Router::increasePosition: _positionSize too large"
            );
        } else {
            require(
                _pos._positionSize <= _info._maxPositionSize,
                "Router::increasePosition: _positionSize too large"
            );
        }

        emit IncreasePosition(
            msg.sender,
            _collateralToken,
            _collateralTokenAmount,
            _leverage,
            _isLong,
            _tradePairTokenPrice
        );
    }

    function decreasePosition(
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _minOrMaxPrice
    ) external payable onlyEOA nonReentrant {
        require(
            _leverage <= maxLeverage,
            "Router::increasePosition: _leverage too large"
        );
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

        // save position
        uint256 _positionSize = _collateralTokenAmount * _leverage;
        bytes32 _posId = getPosId(msg.sender, _collateralToken);
        Position storage _pos = positions[_posId];
        require(
            _pos._collateralTokenAmount > 0,
            "Router::decreasePosition: bad _collateralTokenAmount"
        );
        // check slippage and modify factors
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::decreasePosition: bad _tradePairTokenPrice price"
        );
        if (_isLong) {
            require(
                _tradePairTokenPrice <= _minOrMaxPrice,
                "Router::decreasePosition: can not be larger than _minOrMaxPrice"
            );
        } else {
            require(
                _tradePairTokenPrice >= _minOrMaxPrice,
                "Router::decreasePosition: must be larger than _minOrMaxPrice"
            );
        }
        _changeFactors(_info, _isLong, _positionSize, _tradePairTokenPrice);
        // check direction
        require(
            _pos._isLong == !_isLong,
            "Router::decreasePosition: should not decrease position"
        );
        // close part of pos and update pos
        bool _isReverse = _positionSize >= _pos._positionSize;
        if (_isReverse) {
            uint256 _remainCollateralTokenAmount = _closePartPosition(
                _collateralToken,
                _pos._positionSize,
                _tradePairTokenPrice
            );
            _pos._collateralTokenAmount = _remainCollateralTokenAmount;
            _pos._openPrice = _tradePairTokenPrice;
            _pos._positionSize = _positionSize - _pos._positionSize;
            _pos._isLong = _isLong;
            _pos._leverage = _leverage;
        } else {
            uint256 _remainCollateralTokenAmount = _closePartPosition(
                _collateralToken,
                _positionSize,
                _tradePairTokenPrice
            );
            _pos._collateralTokenAmount = _remainCollateralTokenAmount;
            _pos._positionSize = _pos._positionSize - _positionSize;
        }

        require(
            !_canLiquidate(_pos, _tradePairTokenPrice),
            "Router::decreasePosition: can not liquidate"
        );
        require(
            _pos._positionSize >= _info._minPositionSize,
            "Router::decreasePosition: _positionSize too small"
        );
        emit DecreasePosition(
            msg.sender,
            _collateralToken,
            _collateralTokenAmount,
            _leverage,
            _isLong,
            _tradePairTokenPrice
        );
    }

    function _closePosition(
        Position storage _pos,
        uint256 _tradePairTokenPrice
    ) private {
        SupportTokenInfo storage _info = supportTokenInfos[
            _pos._collateralToken
        ];
        _changeFactors(
            _info,
            !_pos._isLong,
            _pos._positionSize,
            _tradePairTokenPrice
        );
        uint256 _remainCollateralTokenAmount = _closePartPosition(
            _pos._collateralToken,
            _pos._positionSize,
            _tradePairTokenPrice
        );
        if (_remainCollateralTokenAmount > 0) {
            SafeToken.safeTransfer(
                _pos._collateralToken,
                msg.sender,
                _remainCollateralTokenAmount
            );
        }
        _pos._collateralTokenAmount = 0;
        _pos._positionSize = 0;
    }

    function closePosition(
        address _collateralToken
    ) external onlyEOA nonReentrant {
        Position storage _pos = positions[
            getPosId(msg.sender, _collateralToken)
        ];
        require(
            _pos._positionSize > 0,
            "Router::closePosition: target position size not enough"
        );
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::closePosition: bad _tradePairTokenPrice price"
        );
        _closePosition(_pos, _tradePairTokenPrice);
    }

    function _closePartPosition(
        address _collateralToken,
        uint256 _needClosePositionSize,
        uint256 _tradePairTokenPrice
    ) private returns (uint256) {
        Position storage _pos = positions[
            getPosId(msg.sender, _collateralToken)
        ];
        require(
            _pos._positionSize >= _needClosePositionSize,
            "Router::_closePartPosition: target position size not enough"
        );

        int256 _profit = _getPosProfit(
            _pos,
            _tradePairTokenPrice,
            _needClosePositionSize
        );
        uint256 _remainCollateralTokenAmount = _pos._collateralTokenAmount;
        if (_profit >= 0) {
            vaultGateway.sendProfit(
                msg.sender,
                _pos._collateralToken,
                uint256(_profit)
            );
        } else {
            uint256 _loss = uint256(-_profit);
            if (_loss <= _remainCollateralTokenAmount) {
                _remainCollateralTokenAmount =
                    _remainCollateralTokenAmount -
                    _loss;
            } else {
                _remainCollateralTokenAmount = 0;
                _loss = _remainCollateralTokenAmount;
            }

            SafeToken.safeApprove(
                _pos._collateralToken,
                address(vaultGateway),
                _loss
            );
            vaultGateway.receiveLoss(_pos._collateralToken, _loss);
        }
        supportTokenInfos[_collateralToken]._realizedProfit += _profit;
        emit ClosePosition(
            msg.sender,
            _collateralToken,
            _needClosePositionSize,
            _tradePairTokenPrice,
            _profit
        );
        return _remainCollateralTokenAmount;
    }
}
