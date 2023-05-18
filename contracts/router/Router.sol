// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracle} from "../interface/IPriceOracle.sol";
import {IUtopiaToken} from "../interface/IUtopiaToken.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IWeth} from "../interface/IWeth.sol";
import {IRouter} from "../interface/IRouter.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";
import {IInviteManager} from "../interface/IInviteManager.sol";
import {IFeeReceiver} from "../interface/IFeeReceiver.sol";

struct Position {
    bytes32 _posId;
    uint256 _openPrice;
    address _collateralToken;
    uint256 _collateralTokenAmount; // amount of collateral
    uint256 _leverage;
    uint256 _positionSize; // _collateralTokenAmount * leverage
    bool _isLong;
    int256 _initialAccuFundingFeePerOiLong;
    int256 _initialAccuFundingFeePerOiShort;
    uint256 _openTime;
}

struct PosFundInfo {
    int256 _tradeProfit;
    uint256 _rolloverFee;
    int256 _fundingFee;
    uint256 _closeFee;
    int256 _profit;
}

struct SupportTokenInfo {
    uint256 _longOpenPrice;
    uint256 _longPosSizeTotal; // A1+A2+.._An
    uint256 _shortOpenPrice;
    uint256 _shortPosSizeTotal; // A1+A2+.._An
    int256 _realizedTradeProfit; // realized profit of _collateralToken. totalFloat = totalLongFloat + totalShortFloat - _realizedTradeProfit
    int256 _accuFundingFeePerOiLong; // ?/(10 ** 18)
    int256 _accuFundingFeePerOiShort; // ?/(10 ** 18)
    uint256 _lastAccuFundingFeeTime;
}

struct SupportTokenConfig {
    bool _enabled;
    address _collateralToken;
    uint256 _collateralRate; // ?/10000
    uint256 _minPositionSize;
    uint256 _maxPositionSize;
    uint256 _upsMaxPositionSizeRate; // ?/10000
    uint256 _openPositionFeeRate; // ?/10000
    uint256 _closePositionFeeRate; // ?/10000
    uint256 _pointDiffRate; // ?/10000
    uint256 _rolloverFeePerSecond; // ?/(10 ** 10) per second
    uint256 _fundingFeePerSecond; //  ?/(10 ** 10) per second
}

// BTC/USD or ETH/USD or ... Router
contract Router is OwnableUpgradeable, ReentrancyGuardUpgradeable, IRouter {
    event IncreasePosition(
        address indexed _user,
        address indexed _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice
    );

    event NewPosition(
        address indexed _user,
        address indexed _collateralToken,
        bytes32 _posId,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice,
        uint256 _time
    );

    event DecreasePosition(
        address indexed _user,
        address indexed _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice
    );

    event ClosePartPosition(
        address indexed _user,
        address indexed _collateralToken,
        uint256 _closedPositionSize,
        uint256 _tradePairTokenPrice,
        int256 _profit
    );

    event ClosePosition(
        address indexed _user,
        address indexed _collateralToken,
        uint256 _tradePairTokenPrice,
        int256 _profit
    );

    event TradeHistory(
        address indexed _user,
        address indexed _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _tradePairTokenPrice,
        uint256 _positionSize,
        uint256 _leverage,
        bool _isLong,
        int256 _profit,
        uint256 _openFee,
        uint256 _closeFee,
        uint256 _time
    );

    event RebateRecordEvent(
        address indexed _inviter,
        address _invitee,
        address _token,
        uint256 _tokenAmount,
        uint256 _rebates,
        uint256 _time
    );

    address[] public supportTokens;
    mapping(address => SupportTokenConfig) public supportTokenConfigs;
    mapping(address => SupportTokenInfo) public supportTokenInfos; // _collateralToken => SupportTokenInfo

    IPriceOracle public priceOracle;
    address public tradePairToken; // BTC/ETH/...

    mapping(address => mapping(address => Position)) public positions; // user => (_collateralToken => Position)
    IVaultGateway public vaultGateway;
    address public weth;
    mapping(address => bool) public liquidators;
    uint256 public maxLeverage;
    IInviteManager public inviteManager;
    IFeeReceiver public feeReceiver;

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "VaultGateway::onlyEOA:: not eoa");
        _;
    }

    modifier onlyLiquidatorOrOwner() {
        require(
            liquidators[msg.sender] || msg.sender == owner(),
            "VaultGateway::onlyLiquidatorOrOwner:: not liquidator or owner"
        );
        _;
    }

    function initialize(
        address _priceOracle,
        address _tradePairToken,
        address _vaultGateway,
        address _weth,
        SupportTokenConfig[] memory _supportTokenConfigs,
        address _inviteManager,
        address _feeReceiver,
        address[] memory _liquidators
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracle(_priceOracle);
        tradePairToken = _tradePairToken;
        vaultGateway = IVaultGateway(_vaultGateway);
        weth = _weth;
        for (uint256 i = 0; i < _supportTokenConfigs.length; i++) {
            supportTokenConfigs[
                _supportTokenConfigs[i]._collateralToken
            ] = _supportTokenConfigs[i];
            supportTokens.push(_supportTokenConfigs[i]._collateralToken);
        }
        maxLeverage = 100;
        inviteManager = IInviteManager(_inviteManager);
        feeReceiver = IFeeReceiver(_feeReceiver);
        for (uint256 i = 0; i < _liquidators.length; i++) {
            liquidators[_liquidators[i]] = true;
        }
    }

    function changeLiquidators(
        address[] memory _liquidators
    ) external onlyOwner {
        for (uint256 i = 0; i < _liquidators.length; i++) {
            liquidators[_liquidators[i]] = true;
        }
    }

    function changeInviteManager(address _inviteManager) external onlyOwner {
        inviteManager = IInviteManager(_inviteManager);
    }

    function changeFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = IFeeReceiver(_feeReceiver);
    }

    function changeSupportTokenInfos(
        SupportTokenConfig[] memory _supportTokenConfigs
    ) external onlyOwner {
        delete supportTokens;
        for (uint256 i = 0; i < _supportTokenConfigs.length; i++) {
            supportTokenConfigs[
                _supportTokenConfigs[i]._collateralToken
            ] = _supportTokenConfigs[i];
            supportTokens.push(_supportTokenConfigs[i]._collateralToken);
        }
    }

    function changeMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        maxLeverage = _maxLeverage;
    }

    function supportTokenNum() external view returns (uint256) {
        return supportTokens.length;
    }

    // long float
    function totalLongFloat() public view returns (int256[] memory) {
        int256[] memory _floats = new int256[](supportTokens.length);
        for (uint256 i = 0; i < supportTokens.length; i++) {
            SupportTokenInfo memory _supportTokenInfo = supportTokenInfos[
                supportTokens[i]
            ];
            if (_supportTokenInfo._longPosSizeTotal == 0) {
                _floats[i] = 0;
                continue;
            }
            uint256 _tradePairTokenPrice = _price(tradePairToken);
            _floats[i] = (int256(
                (_tradePairTokenPrice * _supportTokenInfo._longPosSizeTotal) /
                    _supportTokenInfo._longOpenPrice
            ) - int256(_supportTokenInfo._longPosSizeTotal));
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
            if (_supportTokenInfo._shortPosSizeTotal == 0) {
                _floats[i] = 0;
                continue;
            }
            uint256 _tradePairTokenPrice = _price(tradePairToken);
            _floats[i] = (int256(_supportTokenInfo._shortPosSizeTotal) -
                int256(
                    (_tradePairTokenPrice *
                        _supportTokenInfo._shortPosSizeTotal) /
                        _supportTokenInfo._shortOpenPrice
                ));
        }
        return _floats;
    }

    function _price(address _token) private view returns (uint256) {
        uint256 _tokenPrice = priceOracle.getAssetPrice(_token);
        require(_tokenPrice > 0, "Router::_price: bad _tokenPrice price");
        return _tokenPrice;
    }

    // total float usd amount except ups
    function totalFloat() external view returns (int256) {
        int256[] memory _totalLongFloat = totalLongFloat();
        int256[] memory _totalShortFloat = totalShortFloat();
        int256 result;
        for (uint256 i = 0; i < supportTokens.length; i++) {
            address _token = supportTokens[i];
            if (_token == address(vaultGateway.utopiaToken())) {
                continue;
            }
            result =
                result +
                ((_totalLongFloat[i] +
                    _totalShortFloat[i] -
                    supportTokenInfos[_token]._realizedTradeProfit) *
                    int256(_price(_token))) /
                int256(10 ** IERC20MetadataUpgradeable(_token).decimals());
        }
        return result;
    }

    // total float ups amount
    function upsTotalFloat() external view returns (int256) {
        int256[] memory _totalLongFloat = totalLongFloat();
        int256[] memory _totalShortFloat = totalShortFloat();
        int256 result;
        for (uint256 i = 0; i < supportTokens.length; i++) {
            address _token = supportTokens[i];
            if (_token == address(vaultGateway.utopiaToken())) {
                result =
                    _totalLongFloat[i] +
                    _totalShortFloat[i] -
                    supportTokenInfos[_token]._realizedTradeProfit;
                break;
            }
        }
        return result;
    }

    function _canLiquidate(
        Position memory _pos,
        uint256 _tradePairTokenPrice
    ) private view returns (bool) {
        if (_pos._positionSize == 0) {
            return false;
        }
        SupportTokenInfo memory _info = supportTokenInfos[
            _pos._collateralToken
        ];
        PosFundInfo memory _posFundInfo = _getPosInfo(
            _pos,
            _tradePairTokenPrice,
            _info,
            _pos._positionSize
        );
        if (_posFundInfo._profit >= 0) {
            return false;
        }
        return
            uint256(-_posFundInfo._profit) >=
            (_pos._collateralTokenAmount *
                supportTokenConfigs[_pos._collateralToken]._collateralRate) /
                10000;
    }

    function posInfoForLiq(
        address _account,
        address _collateralToken
    )
        external
        view
        onlyLiquidatorOrOwner
        returns (Position memory, PosFundInfo memory)
    {
        Position memory _pos = positions[_account][_collateralToken];
        SupportTokenInfo memory _info = supportTokenInfos[
            _pos._collateralToken
        ];
        uint256 _tradePairTokenPrice = _price(tradePairToken);
        PosFundInfo memory _posFundInfo = _getPosInfo(
            _pos,
            _tradePairTokenPrice,
            _info,
            _pos._positionSize
        );
        return (_pos, _posFundInfo);
    }

    function liquidate(
        address _account,
        address _collateralToken
    ) external onlyLiquidatorOrOwner {
        Position storage _pos = positions[_account][_collateralToken];
        uint256 _tradePairTokenPrice = _price(tradePairToken);
        require(
            _canLiquidate(_pos, _tradePairTokenPrice),
            "Router::liquidate: can not liquidate"
        );
        _decreasePosition(
            supportTokenInfos[_pos._collateralToken],
            supportTokenConfigs[_pos._collateralToken],
            _pos,
            0,
            0,
            !_pos._isLong,
            _tradePairTokenPrice,
            true
        );
    }

    function getPosInfo(
        address _collateralToken
    ) external view returns (PosFundInfo memory) {
        SupportTokenInfo memory _info = supportTokenInfos[_collateralToken];
        Position memory _pos = positions[msg.sender][_collateralToken];
        uint256 _tradePairTokenPrice = _price(tradePairToken);

        return
            _getPosInfo(_pos, _tradePairTokenPrice, _info, _pos._positionSize);
    }

    function fundingFeePerHour(
        address _collateralToken
    ) external view returns (int256, int256) {
        SupportTokenInfo memory _info = supportTokenInfos[_collateralToken];
        SupportTokenConfig memory _supportTokenConfig = supportTokenConfigs[
            _collateralToken
        ];
        int256 _diff = int256(_info._longPosSizeTotal) -
            int256(_info._shortPosSizeTotal);
        int256 _longResult = 0;
        int256 _shortResult = 0;
        if (_info._longPosSizeTotal > 0) {
            _longResult =
                (_diff *
                    int256(_supportTokenConfig._fundingFeePerSecond * 3600)) /
                int256(_info._longPosSizeTotal);
        }
        if (_info._shortPosSizeTotal > 0) {
            _shortResult =
                (-_diff *
                    int256(3600 * _supportTokenConfig._fundingFeePerSecond)) /
                int256(_info._shortPosSizeTotal);
        }
        return (_longResult, _shortResult);
    }

    function _getPosInfo(
        Position memory _pos,
        uint256 _tradePairTokenPrice,
        SupportTokenInfo memory _info,
        uint256 _positionSize
    ) private view returns (PosFundInfo memory) {
        if (_pos._positionSize == 0) {
            return PosFundInfo(0, 0, 0, 0, 0);
        }
        SupportTokenConfig memory _supportTokenConfig = supportTokenConfigs[
            _pos._collateralToken
        ];
        uint256 _rolloverFee = ((block.timestamp - _pos._openTime) *
            _supportTokenConfig._rolloverFeePerSecond *
            _positionSize) / (10 ** 10);
        int256 _fundingFee = 0;

        int256 _tradeProfit = 0;
        int256 _diff = int256(_info._longPosSizeTotal) -
            int256(_info._shortPosSizeTotal);
        if (_pos._isLong) {
            if (_info._longPosSizeTotal > 0) {
                _fundingFee =
                    ((_info._accuFundingFeePerOiLong +
                        ((_diff *
                            int256(
                                (block.timestamp -
                                    _info._lastAccuFundingFeeTime) *
                                    _supportTokenConfig._fundingFeePerSecond
                            )) * (10 ** 8)) /
                        int256(_info._longPosSizeTotal) -
                        _pos._initialAccuFundingFeePerOiLong) *
                        int256(_positionSize)) /
                    (10 ** 18);
            }

            _tradeProfit =
                int256(
                    (_tradePairTokenPrice * _positionSize) / _pos._openPrice
                ) -
                int256(_positionSize);
        } else {
            if (_info._shortPosSizeTotal > 0) {
                _fundingFee =
                    ((_info._accuFundingFeePerOiShort +
                        ((-_diff *
                            int256(
                                (block.timestamp -
                                    _info._lastAccuFundingFeeTime) *
                                    _supportTokenConfig._fundingFeePerSecond
                            )) * (10 ** 8)) /
                        int256(_info._shortPosSizeTotal) -
                        _pos._initialAccuFundingFeePerOiShort) *
                        int256(_positionSize)) /
                    (10 ** 18);
            }

            _tradeProfit =
                int256(_positionSize) -
                int256(
                    (_tradePairTokenPrice * _positionSize) / _pos._openPrice
                );
        }
        uint256 _closeFee = (_positionSize *
            _supportTokenConfig._closePositionFeeRate) / 10000;
        int256 _profit = _tradeProfit -
            int256(_rolloverFee) -
            _fundingFee -
            int256(_closeFee);
        return
            PosFundInfo(
                _tradeProfit,
                _rolloverFee,
                _fundingFee,
                _closeFee,
                _profit
            );
    }

    function _whenPosChanged(
        SupportTokenInfo storage _info,
        Position storage _pos,
        SupportTokenConfig memory _supportTokenConfig,
        bool _isLong,
        uint256 _positionSize,
        uint256 _tradePairTokenPrice
    ) private {
        if (_isLong) {
            _info._longPosSizeTotal = _info._longPosSizeTotal + _positionSize;
        } else {
            _info._shortPosSizeTotal = _info._shortPosSizeTotal + _positionSize;
        }
        _accuFundingFee(_info, _supportTokenConfig);
        _settlementFundingFee(_info, _pos, _tradePairTokenPrice, _positionSize);
        _combineGlobalPosition(
            _info,
            _tradePairTokenPrice,
            _positionSize,
            _isLong
        );
    }

    function _combineGlobalPosition(
        SupportTokenInfo storage _info,
        uint256 _tradePairTokenPrice,
        uint256 _positionSize,
        bool _isLong
    ) private {
        if (_isLong) {
            if (_info._longOpenPrice == 0) {
                _info._longOpenPrice = _tradePairTokenPrice;
            } else {
                _info._longOpenPrice =
                    (_info._longOpenPrice *
                        _tradePairTokenPrice *
                        (_info._longPosSizeTotal)) /
                    (_tradePairTokenPrice *
                        (_info._longPosSizeTotal - _positionSize) +
                        _info._longOpenPrice *
                        _positionSize);
            }
        } else {
            if (_info._shortOpenPrice == 0) {
                _info._shortOpenPrice = _tradePairTokenPrice;
            } else {
                _info._shortOpenPrice =
                    (_info._shortOpenPrice *
                        _tradePairTokenPrice *
                        (_info._shortPosSizeTotal)) /
                    (_tradePairTokenPrice *
                        (_info._shortPosSizeTotal - _positionSize) +
                        _info._shortOpenPrice *
                        _positionSize);
            }
        }
    }

    function accuAllFundingFee() external {
        for (uint256 i = 0; i < supportTokens.length; i++) {
            _accuFundingFee(
                supportTokenInfos[supportTokens[i]],
                supportTokenConfigs[supportTokens[i]]
            );
        }
    }

    function _settlementFundingFee(
        SupportTokenInfo storage _info,
        Position storage _pos,
        uint256 _tradePairTokenPrice,
        uint256 _positionSize
    ) private {
        PosFundInfo memory _posFundInfo = _getPosInfo(
            _pos,
            _tradePairTokenPrice,
            _info,
            _positionSize
        );
        if (_posFundInfo._fundingFee >= 0) {
            _pos._collateralTokenAmount -= uint256(_posFundInfo._fundingFee);
        } else {
            _pos._collateralTokenAmount += uint256(-_posFundInfo._fundingFee);
        }
        _pos._initialAccuFundingFeePerOiLong = _info._accuFundingFeePerOiLong;
        _pos._initialAccuFundingFeePerOiShort = _info._accuFundingFeePerOiShort;
    }

    function _accuFundingFee(
        SupportTokenInfo storage _info,
        SupportTokenConfig memory _supportTokenConfig
    ) private {
        if (_info._lastAccuFundingFeeTime != 0) {
            int256 _diff = int256(_info._longPosSizeTotal) -
                int256(_info._shortPosSizeTotal);
            if (_info._longPosSizeTotal > 0) {
                _info._accuFundingFeePerOiLong +=
                    ((_diff *
                        int256(
                            (block.timestamp - _info._lastAccuFundingFeeTime) *
                                _supportTokenConfig._fundingFeePerSecond
                        )) * (10 ** 8)) /
                    int256(_info._longPosSizeTotal);
            }
            if (_info._shortPosSizeTotal > 0) {
                _info._accuFundingFeePerOiShort +=
                    ((-_diff *
                        int256(
                            (block.timestamp - _info._lastAccuFundingFeeTime) *
                                _supportTokenConfig._fundingFeePerSecond
                        )) * (10 ** 8)) /
                    int256(_info._shortPosSizeTotal);
            }
        }
        _info._lastAccuFundingFeeTime = block.timestamp;
    }

    function increasePosition(
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _minOrMaxPrice,
        address _inviter
    ) external payable onlyEOA nonReentrant {
        require(
            _leverage <= maxLeverage,
            "Router::increasePosition: _leverage too large"
        );
        // check _collateralToken
        require(
            supportTokenConfigs[_collateralToken]._enabled,
            "Router::increasePosition: not support this token"
        );

        SupportTokenInfo storage _info = supportTokenInfos[_collateralToken];
        SupportTokenConfig memory _supportTokenConfig = supportTokenConfigs[
            _collateralToken
        ];
        uint256 _tradePairTokenPrice = _tradePairTokenPriceAndCheck(
            _isLong,
            _supportTokenConfig._pointDiffRate,
            _minOrMaxPrice
        );

        uint256 _openFee = (_collateralTokenAmount *
            _supportTokenConfig._openPositionFeeRate) / 10000;
        if (_collateralTokenAmount > 0) {
            SafeToken.safeTransferFrom(
                _collateralToken,
                msg.sender,
                address(this),
                _collateralTokenAmount
            );
            if (_openFee > 0) {
                _collateralTokenAmount -= _openFee;

                _openFee = _processInviteReward(_collateralToken, _openFee);
                SafeToken.safeApprove(
                    _collateralToken,
                    address(feeReceiver),
                    _openFee
                );
                feeReceiver.receiveFee(_collateralToken, _openFee);
            }
        }
        Position storage _pos = positions[msg.sender][_collateralToken];
        _pos._collateralToken = _collateralToken;
        _pos._collateralTokenAmount += _collateralTokenAmount;
        _pos._isLong = _isLong;
        _whenPosChanged(
            _info,
            _pos,
            _supportTokenConfig,
            _isLong,
            _collateralTokenAmount * _leverage,
            _tradePairTokenPrice
        );
        if (_pos._positionSize == 0) {
            // new position
            _newPosition(_pos, _inviter, _leverage, _tradePairTokenPrice);
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
                    (_pos._positionSize + _collateralTokenAmount * _leverage)) /
                (_pos._openPrice *
                    _collateralTokenAmount *
                    _leverage +
                    _tradePairTokenPrice *
                    _pos._positionSize);
            _pos._positionSize =
                _pos._positionSize +
                _collateralTokenAmount *
                _leverage;
        }
        require(
            !_canLiquidate(_pos, _tradePairTokenPrice),
            "Router::increasePosition: can not liquidate"
        );
        _checkPositionSize(_supportTokenConfig, _pos);

        emit IncreasePosition(
            msg.sender,
            _collateralToken,
            _collateralTokenAmount,
            _leverage,
            _isLong,
            _tradePairTokenPrice
        );
        emit TradeHistory(
            msg.sender,
            _collateralToken,
            _collateralTokenAmount,
            _tradePairTokenPrice,
            _collateralTokenAmount * _leverage,
            _leverage,
            _isLong,
            0,
            _openFee,
            0,
            block.timestamp
        );
    }

    function _tradePairTokenPriceAndCheck(
        bool _isLong,
        uint256 _pointDiffRate,
        uint256 _minOrMaxPrice
    ) private view returns (uint256) {
        uint256 _tradePairTokenPrice = _price(tradePairToken);
        if (_isLong) {
            _tradePairTokenPrice =
                _tradePairTokenPrice +
                (_tradePairTokenPrice * _pointDiffRate) /
                10000;
            require(
                _tradePairTokenPrice <= _minOrMaxPrice,
                "Router::_tradePairTokenPriceAndCheck: can not be larger than _minOrMaxPrice"
            );
        } else {
            _tradePairTokenPrice =
                _tradePairTokenPrice -
                (_tradePairTokenPrice * _pointDiffRate) /
                10000;
            require(
                _tradePairTokenPrice >= _minOrMaxPrice,
                "Router::_tradePairTokenPriceAndCheck: must be larger than _minOrMaxPrice"
            );
        }
        return _tradePairTokenPrice;
    }

    function _newPosition(
        Position storage _pos,
        address _inviter,
        uint256 _leverage,
        uint256 _tradePairTokenPrice
    ) private {
        _pos._posId = keccak256(
            abi.encodePacked(msg.sender, _pos._collateralToken, block.timestamp)
        );
        _pos._openPrice = _tradePairTokenPrice;
        _pos._leverage = _leverage;
        _pos._positionSize = _pos._collateralTokenAmount * _leverage;

        _pos._openTime = block.timestamp;

        if (address(inviteManager) != address(0)) {
            inviteManager.tryInvite(_inviter, msg.sender);
        }
        emit NewPosition(
            msg.sender,
            _pos._collateralToken,
            _pos._posId,
            _pos._collateralTokenAmount,
            _pos._leverage,
            _pos._isLong,
            _tradePairTokenPrice,
            block.timestamp
        );
    }

    function _checkPositionSize(
        SupportTokenConfig memory _supportTokenConfig,
        Position memory _pos
    ) private view {
        require(
            _pos._positionSize >= _supportTokenConfig._minPositionSize,
            "Router::_decreasePosition: _positionSize too small"
        );

        if (_pos._collateralToken == address(vaultGateway.utopiaToken())) {
            require(
                _pos._positionSize <=
                    (vaultGateway.utopiaToken().totalSupply() *
                        _supportTokenConfig._upsMaxPositionSizeRate) /
                        10000,
                "Router::increasePosition: _positionSize too large"
            );
        } else {
            require(
                _pos._positionSize <= _supportTokenConfig._maxPositionSize,
                "Router::increasePosition: _positionSize too large"
            );
        }
    }

    function decreasePosition(
        address _collateralToken,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _minOrMaxPrice,
        bool _isClosePos
    ) external payable onlyEOA nonReentrant {
        require(
            _leverage <= maxLeverage,
            "Router::increasePosition: _leverage too large"
        );
        SupportTokenInfo storage _info = supportTokenInfos[_collateralToken];
        SupportTokenConfig memory _supportTokenConfig = supportTokenConfigs[
            _collateralToken
        ];
        Position storage _pos = positions[msg.sender][_collateralToken];

        uint256 _tradePairTokenPrice = _tradePairTokenPriceAndCheck(
            _isLong,
            _supportTokenConfig._pointDiffRate,
            _minOrMaxPrice
        );

        _decreasePosition(
            _info,
            _supportTokenConfig,
            _pos,
            _collateralTokenAmount,
            _leverage,
            _isLong,
            _tradePairTokenPrice,
            _isClosePos
        );
    }

    function _decreasePosition(
        SupportTokenInfo storage _info,
        SupportTokenConfig memory _supportTokenConfig,
        Position storage _pos,
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice,
        bool _isClosePos
    ) private {
        // check direction
        require(
            _pos._isLong == !_isLong,
            "Router::_decreasePosition: should not decrease position"
        );
        uint256 _positionSize = _pos._positionSize;
        if (_positionSize == _collateralTokenAmount * _leverage) {
            _isClosePos = true;
        }
        if (_isClosePos) {
            // close position
            _whenPosChanged(
                _info,
                _pos,
                _supportTokenConfig,
                _isLong,
                _positionSize,
                _tradePairTokenPrice
            );
            (
                uint256 _remainCollateralTokenAmount,
                int256 _profit,
                uint256 _closeFee
            ) = _closePartPosition(_pos, _positionSize, _tradePairTokenPrice);
            if (_remainCollateralTokenAmount > 0) {
                SafeToken.safeTransfer(
                    _pos._collateralToken,
                    msg.sender,
                    _remainCollateralTokenAmount
                );
            }

            _pos._collateralTokenAmount = 0;
            _pos._positionSize = 0;
            emit ClosePosition(
                msg.sender,
                _pos._collateralToken,
                _tradePairTokenPrice,
                _profit
            );
            emit TradeHistory(
                msg.sender,
                _pos._collateralToken,
                _collateralTokenAmount,
                _tradePairTokenPrice,
                _positionSize,
                _pos._leverage,
                _isLong,
                _profit,
                0,
                _closeFee,
                block.timestamp
            );
        } else {
            require(
                _pos._collateralTokenAmount > 0,
                "Router::_decreasePosition: bad _collateralTokenAmount"
            );
            // transfer in _collateralToken

            uint256 _openFee = (_collateralTokenAmount *
                _supportTokenConfig._openPositionFeeRate) / 10000;
            if (_collateralTokenAmount > 0) {
                SafeToken.safeTransferFrom(
                    _pos._collateralToken,
                    msg.sender,
                    address(this),
                    _collateralTokenAmount
                );
                if (_openFee > 0) {
                    SafeToken.safeApprove(
                        _pos._collateralToken,
                        address(feeReceiver),
                        _openFee
                    );
                    feeReceiver.receiveFee(_pos._collateralToken, _openFee);
                    _collateralTokenAmount -= _openFee;
                }
            }
            _pos._collateralTokenAmount += _collateralTokenAmount;
            _positionSize = _collateralTokenAmount * _leverage;
            int256 _profit = 0;
            uint256 _closeFee = 0;
            if (_positionSize > _pos._positionSize) {
                // reverse
                _whenPosChanged(
                    _info,
                    _pos,
                    _supportTokenConfig,
                    _isLong,
                    _pos._positionSize,
                    _tradePairTokenPrice
                );
                (
                    uint256 _remainCollateralTokenAmount,
                    int256 __profit,
                    uint256 __closeFee
                ) = _closePartPosition(
                        _pos,
                        _pos._positionSize,
                        _tradePairTokenPrice
                    );
                _closeFee = __closeFee;
                _profit = __profit;
                _pos._collateralTokenAmount = _remainCollateralTokenAmount;
                _pos._openPrice = _tradePairTokenPrice;
                _pos._positionSize = _positionSize - _pos._positionSize;
                _pos._isLong = _isLong;
                _pos._leverage = _leverage;
            } else {
                // decrease position
                _whenPosChanged(
                    _info,
                    _pos,
                    _supportTokenConfig,
                    _isLong,
                    _positionSize,
                    _tradePairTokenPrice
                );
                (
                    uint256 _remainCollateralTokenAmount,
                    int256 __profit,
                    uint256 __closeFee
                ) = _closePartPosition(
                        _pos,
                        _positionSize,
                        _tradePairTokenPrice
                    );
                _closeFee = __closeFee;
                _profit = __profit;
                _pos._collateralTokenAmount = _remainCollateralTokenAmount;
                _pos._positionSize = _pos._positionSize - _positionSize;
            }
            require(
                !_canLiquidate(_pos, _tradePairTokenPrice),
                "Router::_decreasePosition: can not liquidate"
            );
            require(
                _pos._positionSize >= _supportTokenConfig._minPositionSize,
                "Router::_decreasePosition: _positionSize too small"
            );
            emit TradeHistory(
                msg.sender,
                _pos._collateralToken,
                _collateralTokenAmount,
                _tradePairTokenPrice,
                _collateralTokenAmount * _leverage,
                _leverage,
                _isLong,
                _profit,
                _openFee,
                _closeFee,
                block.timestamp
            );
        }

        emit DecreasePosition(
            msg.sender,
            _pos._collateralToken,
            _collateralTokenAmount,
            _leverage,
            _isLong,
            _tradePairTokenPrice
        );
    }

    function _processInviteReward(
        address _token,
        uint256 _amount
    ) private returns (uint256) {
        if (
            address(inviteManager) != address(0) &&
            inviteManager.inviters(msg.sender) != address(0)
        ) {
            uint256 _inviteReward = (_amount *
                inviteManager.inviteRateOfNftSell()) / 10000;
            SafeToken.safeTransfer(
                _token,
                inviteManager.inviters(msg.sender),
                _inviteReward
            );
            emit RebateRecordEvent(
                inviteManager.inviters(msg.sender),
                msg.sender,
                _token,
                _amount,
                _inviteReward,
                block.timestamp
            );
            return _amount - _inviteReward;
        }
        return _amount;
    }

    function _closePartPosition(
        Position memory _pos,
        uint256 _needClosePositionSize,
        uint256 _tradePairTokenPrice
    ) private returns (uint256, int256, uint256) {
        require(
            _pos._positionSize >= _needClosePositionSize,
            "Router::_closePartPosition: target position size not enough"
        );

        SupportTokenInfo storage _info = supportTokenInfos[
            _pos._collateralToken
        ];

        PosFundInfo memory _posFundInfo = _getPosInfo(
            _pos,
            _tradePairTokenPrice,
            _info,
            _needClosePositionSize
        );

        uint256 _remainCollateralTokenAmount = _pos._collateralTokenAmount;

        uint256 _rolloverAndCloseFee = _processInviteReward(
            _pos._collateralToken,
            _posFundInfo._closeFee
        ) + _posFundInfo._rolloverFee;
        if (_rolloverAndCloseFee >= _remainCollateralTokenAmount) {
            _rolloverAndCloseFee = _remainCollateralTokenAmount;
            _remainCollateralTokenAmount = 0;
        } else {
            _remainCollateralTokenAmount -= _rolloverAndCloseFee;
        }
        if (_rolloverAndCloseFee > 0) {
            SafeToken.safeApprove(
                _pos._collateralToken,
                address(feeReceiver),
                _rolloverAndCloseFee
            );
            feeReceiver.receiveFee(_pos._collateralToken, _rolloverAndCloseFee);
        }

        if (_posFundInfo._tradeProfit > 0) {
            vaultGateway.sendProfit(
                msg.sender,
                _pos._collateralToken,
                uint256(_posFundInfo._tradeProfit)
            );
        } else if (_posFundInfo._tradeProfit < 0) {
            uint256 _loss = uint256(-_posFundInfo._tradeProfit);
            if (_loss >= _remainCollateralTokenAmount) {
                _loss = _remainCollateralTokenAmount;
                _remainCollateralTokenAmount = 0;
            } else {
                _remainCollateralTokenAmount -= _loss;
            }
            if (_loss > 0) {
                SafeToken.safeApprove(
                    _pos._collateralToken,
                    address(vaultGateway),
                    _loss
                );
                vaultGateway.receiveLoss(_pos._collateralToken, _loss);
            }
        }
        _info._realizedTradeProfit += _posFundInfo._tradeProfit;


        emit ClosePartPosition(
            msg.sender,
            _pos._collateralToken,
            _needClosePositionSize,
            _tradePairTokenPrice,
            _posFundInfo._profit
        );
        return (
            _remainCollateralTokenAmount,
            _posFundInfo._profit,
            _posFundInfo._closeFee
        );
    }
}
