// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracle} from "../interface/IPriceOracle.sol";
import {IUtopiaToken} from "../interface/IUtopiaToken.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IWeth} from "../interface/IWeth.sol";
import {IRouter, SupportTokenInfo, FeeInfo} from "../interface/IRouter.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";
import {IInviteManager} from "../interface/IInviteManager.sol";
import {IFeeReceiver} from "../interface/IFeeReceiver.sol";

struct Position {
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
        uint256 _collateralTokenAmount,
        uint256 _leverage,
        bool _isLong,
        uint256 _tradePairTokenPrice
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
        uint256 _tradePairTokenPrice,
        uint256 _positionSize,
        uint256 _leverage,
        bool _isLong,
        int256 _profit,
        uint256 _openFee,
        uint256 _closeFee,
        uint256 _time
    );

    address[] public supportTokens;
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
        SupportTokenInfo[] memory _supportTokenInfos,
        address _inviteManager,
        address _feeReceiver
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracle(_priceOracle);
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
        inviteManager = IInviteManager(_inviteManager);
        feeReceiver = IFeeReceiver(_feeReceiver);
    }

    function changeInviteManager(address _inviteManager) external onlyOwner {
        inviteManager = IInviteManager(_inviteManager);
    }

    function changeFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = IFeeReceiver(_feeReceiver);
    }

    function changeSupportTokenInfos(
        SupportTokenInfo[] memory _supportTokenInfos
    ) external onlyOwner {
        delete supportTokens;
        for (uint256 i = 0; i < _supportTokenInfos.length; i++) {
            supportTokenInfos[
                _supportTokenInfos[i]._collateralToken
            ] = _supportTokenInfos[i];
            supportTokens.push(_supportTokenInfos[i]._collateralToken);
        }
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
            uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
                tradePairToken
            );
            require(
                _tradePairTokenPrice > 0,
                "Router::totalLongFloat: bad _tradePairTokenPrice price"
            );
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
            uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
                tradePairToken
            );
            require(
                _tradePairTokenPrice > 0,
                "Router::totalShortFloat: bad _tradePairTokenPrice price"
            );
            _floats[i] = (int256(_supportTokenInfo._shortPosSizeTotal) -
                int256(
                    (_tradePairTokenPrice *
                        _supportTokenInfo._shortPosSizeTotal) /
                        _supportTokenInfo._shortOpenPrice
                ));
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
                    supportTokenInfos[_token]._realizedTradeProfit) *
                    int256(_tokenPrice)) /
                int256(10 ** IERC20MetadataUpgradeable(_token).decimals());
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
            ((_pos._collateralTokenAmount - uint256(-_posFundInfo._profit)) *
                supportTokenInfos[_pos._collateralToken]._collateralRate) /
                10000;
    }

    function liquidate(
        address _account,
        address _collateralToken
    ) external onlyLiquidator {
        Position storage _pos = positions[_account][_collateralToken];
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
        SupportTokenInfo storage _info = supportTokenInfos[
            _pos._collateralToken
        ];
        _decreasePosition(
            _info,
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
        Position memory _pos = positions[msg.sender][_collateralToken];
        uint256 _tradePairTokenPrice = priceOracle.getAssetPrice(
            tradePairToken
        );
        require(
            _tradePairTokenPrice > 0,
            "Router::getPosProfit: bad _tradePairTokenPrice price"
        );

        SupportTokenInfo memory _info = supportTokenInfos[
            _pos._collateralToken
        ];

        return
            _getPosInfo(_pos, _tradePairTokenPrice, _info, _pos._positionSize);
    }

    function _getPosInfo(
        Position memory _pos,
        uint256 _tradePairTokenPrice,
        SupportTokenInfo memory _info,
        uint256 _positionSize
    ) private view returns (PosFundInfo memory) {
        uint256 _rolloverFee = ((block.timestamp - _pos._openTime) *
            _info._feeInfo._rolloverFeePerSecond *
            _positionSize) /
            _pos._leverage /
            (10 ** 10);
        int256 _fundingFee = 0;

        int256 _tradeProfit = 0;
        int256 _diff = int256(_info._longPosSizeTotal) -
            int256(_info._shortPosSizeTotal);
        if (_pos._isLong) {
            if (_info._longPosSizeTotal > 0) {
                _fundingFee =
                    ((_info._feeInfo._accuFundingFeePerOiLong +
                        ((_diff *
                            int256(
                                (block.timestamp -
                                    _info._feeInfo._lastAccuFundingFeeTime) *
                                    _info._feeInfo._fundingFeePerSecond
                            )) * (10 ** 8)) /
                        int256(_info._longPosSizeTotal) -
                        _pos._initialAccuFundingFeePerOiLong) *
                        int256(_positionSize)) /
                    (10 ** 18);
            }

            _tradeProfit =
                (int256(
                    (_tradePairTokenPrice * _positionSize) / _pos._openPrice
                ) - int256(_positionSize)) /
                int256(_pos._leverage);
        } else {
            if (_info._shortPosSizeTotal > 0) {
                _fundingFee =
                    ((_info._feeInfo._accuFundingFeePerOiShort +
                        ((-_diff *
                            int256(
                                (block.timestamp -
                                    _info._feeInfo._lastAccuFundingFeeTime) *
                                    _info._feeInfo._fundingFeePerSecond
                            )) * (10 ** 8)) /
                        int256(_info._shortPosSizeTotal) -
                        _pos._initialAccuFundingFeePerOiShort) *
                        int256(_positionSize)) /
                    (10 ** 18);
            }

            _tradeProfit =
                (int256(_positionSize) -
                    int256(
                        (_tradePairTokenPrice * _positionSize) / _pos._openPrice
                    )) /
                int256(_pos._leverage);
        }
        uint256 _closeFee = (_positionSize *
            _info._feeInfo._closePositionFeeRate) /
            10000 /
            _pos._leverage;
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

    function _changeFactors(
        SupportTokenInfo storage _info,
        bool _isLong,
        uint256 _positionSize,
        uint256 _tradePairTokenPrice
    ) private {
        _accuFundingFee(_info);
        if (_isLong) {
            if (_info._longPosSizeTotal == 0) {
                _info._longOpenPrice = _tradePairTokenPrice;
            } else {
                _info._longOpenPrice =
                    (_info._longOpenPrice *
                        _tradePairTokenPrice *
                        (_info._longPosSizeTotal + _positionSize)) /
                    (_tradePairTokenPrice *
                        _info._longPosSizeTotal +
                        _info._longOpenPrice *
                        _positionSize);
            }
            _info._longPosSizeTotal = _info._longPosSizeTotal + _positionSize;
        } else {
            if (_info._shortPosSizeTotal == 0) {
                _info._shortOpenPrice = _tradePairTokenPrice;
            } else {
                _info._shortOpenPrice =
                    (_info._shortOpenPrice *
                        _tradePairTokenPrice *
                        (_info._shortPosSizeTotal + _positionSize)) /
                    (_tradePairTokenPrice *
                        _info._shortPosSizeTotal +
                        _info._shortOpenPrice *
                        _positionSize);
            }
            _info._shortPosSizeTotal = _info._shortPosSizeTotal + _positionSize;
        }
    }

    function accuAllFundingFee() external {
        for (uint256 i = 0; i < supportTokens.length; i++) {
            SupportTokenInfo storage _info = supportTokenInfos[
                supportTokens[i]
            ];
            _accuFundingFee(_info);
        }
    }

    function _accuFundingFee(SupportTokenInfo storage _info) private {
        if (_info._feeInfo._lastAccuFundingFeeTime != 0) {
            int256 _diff = int256(_info._longPosSizeTotal) -
                int256(_info._shortPosSizeTotal);
            if (_info._longPosSizeTotal > 0) {
                _info._feeInfo._accuFundingFeePerOiLong +=
                    ((_diff *
                        int256(
                            (block.timestamp -
                                _info._feeInfo._lastAccuFundingFeeTime) *
                                _info._feeInfo._fundingFeePerSecond
                        )) * (10 ** 8)) /
                    int256(_info._longPosSizeTotal);
            }
            if (_info._shortPosSizeTotal > 0) {
                _info._feeInfo._accuFundingFeePerOiShort +=
                    ((-_diff *
                        int256(
                            (block.timestamp -
                                _info._feeInfo._lastAccuFundingFeeTime) *
                                _info._feeInfo._fundingFeePerSecond
                        )) * (10 ** 8)) /
                    int256(_info._shortPosSizeTotal);
            }
        }
        _info._feeInfo._lastAccuFundingFeeTime = block.timestamp;
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
        if (_isLong) {
            _tradePairTokenPrice =
                _tradePairTokenPrice +
                (_tradePairTokenPrice * _info._feeInfo._pointDiff) /
                10000;
            require(
                _tradePairTokenPrice <= _minOrMaxPrice,
                "Router::increasePosition: can not be larger than _minOrMaxPrice"
            );
        } else {
            _tradePairTokenPrice =
                _tradePairTokenPrice -
                (_tradePairTokenPrice * _info._feeInfo._pointDiff) /
                10000;
            require(
                _tradePairTokenPrice >= _minOrMaxPrice,
                "Router::increasePosition: must be larger than _minOrMaxPrice"
            );
        }

        // transfer in _collateralToken
        uint256 _openFee = (_collateralTokenAmount *
            _info._feeInfo._openPositionFeeRate) / 10000;
        if (_collateralTokenAmount > 0) {
            SafeToken.safeTransferFrom(
                _collateralToken,
                msg.sender,
                address(this),
                _collateralTokenAmount
            );
            if (_openFee > 0) {
                SafeToken.safeApprove(
                    _collateralToken,
                    address(feeReceiver),
                    _openFee
                );
                feeReceiver.receiveFee(_collateralToken, _openFee);
                _collateralTokenAmount -= _openFee;
            }
        }
        Position storage _pos = positions[msg.sender][_collateralToken];
        _pos._collateralTokenAmount += _collateralTokenAmount;
        uint256 _positionSize = _collateralTokenAmount * _leverage;
        _changeFactors(_info, _isLong, _positionSize, _tradePairTokenPrice);
        if (_pos._positionSize == 0) {
            // new position
            _pos._openPrice = _tradePairTokenPrice;
            _pos._collateralToken = _collateralToken;
            _pos._leverage = _leverage;
            _pos._positionSize = _positionSize;
            _pos._isLong = _isLong;
            _pos._openTime = block.timestamp;
            _pos._initialAccuFundingFeePerOiLong = _info
                ._feeInfo
                ._accuFundingFeePerOiLong;
            _pos._initialAccuFundingFeePerOiShort = _info
                ._feeInfo
                ._accuFundingFeePerOiShort;

            if (address(inviteManager) != address(0)) {
                inviteManager.tryInvite(_inviter, msg.sender);
            }
            emit NewPosition(
                msg.sender,
                _collateralToken,
                _collateralTokenAmount,
                _leverage,
                _isLong,
                _tradePairTokenPrice
            );
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
        }
        require(
            !_canLiquidate(_pos, _tradePairTokenPrice),
            "Router::increasePosition: can not liquidate"
        );
        require(
            _pos._positionSize >= _info._minPositionSize,
            "Router::_decreasePosition: _positionSize too small"
        );
        
        IUtopiaToken _utopiaToken = vaultGateway.utopiaToken();
        if (_pos._collateralToken == address(_utopiaToken)) {
            require(
                _pos._positionSize <=
                    _utopiaToken.totalSupply() * _info._upsMaxPositionSizeRate / 10000,
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
        emit TradeHistory(
            msg.sender,
            _collateralToken,
            _tradePairTokenPrice,
            _pos._positionSize,
            _leverage,
            _pos._isLong,
            0,
            _openFee,
            0,
            block.timestamp
        );
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
        Position storage _pos = positions[msg.sender][_collateralToken];

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
        if (_isLong) {
            _tradePairTokenPrice =
                _tradePairTokenPrice +
                (_tradePairTokenPrice * _info._feeInfo._pointDiff) /
                10000;
        } else {
            _tradePairTokenPrice =
                _tradePairTokenPrice -
                (_tradePairTokenPrice * _info._feeInfo._pointDiff) /
                10000;
        }
        _decreasePosition(
            _info,
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
        int256 _profit = 0;
        uint256 _closeFee = 0;
        uint256 _openFee = 0;
        if (_positionSize == _collateralTokenAmount * _leverage) {
            _isClosePos = true;
        }
        if (_isClosePos) {
            // close position
            _changeFactors(_info, _isLong, _positionSize, _tradePairTokenPrice);
            (
                uint256 _remainCollateralTokenAmount,
                int256 __profit,
                uint256 __closeFee
            ) = _closePartPosition(_pos, _positionSize, _tradePairTokenPrice);
            _profit = __profit;
            _closeFee = __closeFee;
            SafeToken.safeTransfer(
                _pos._collateralToken,
                msg.sender,
                _remainCollateralTokenAmount
            );
            _pos._collateralTokenAmount = 0;
            _pos._positionSize = 0;
            emit ClosePosition(
                msg.sender,
                _pos._collateralToken,
                _tradePairTokenPrice,
                _profit
            );
        } else {
            require(
                _pos._collateralTokenAmount > 0,
                "Router::_decreasePosition: bad _collateralTokenAmount"
            );
            // transfer in _collateralToken

            _openFee =
                (_collateralTokenAmount * _info._feeInfo._openPositionFeeRate) /
                10000;
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
            if (_positionSize > _pos._positionSize) {
                // reverse
                _changeFactors(
                    _info,
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
                _changeFactors(
                    _info,
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
                _pos._positionSize >= _info._minPositionSize,
                "Router::_decreasePosition: _positionSize too small"
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

        emit TradeHistory(
            msg.sender,
            _pos._collateralToken,
            _tradePairTokenPrice,
            _positionSize,
            _pos._leverage,
            _isLong,
            _profit,
            _openFee,
            _closeFee,
            block.timestamp
        );
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
        if (_posFundInfo._tradeProfit > 0) {
            vaultGateway.sendProfit(
                address(this),
                _pos._collateralToken,
                uint256(_posFundInfo._tradeProfit)
            );
        } else if (_posFundInfo._tradeProfit < 0) {
            uint256 _loss = uint256(-_posFundInfo._tradeProfit);

            SafeToken.safeApprove(
                _pos._collateralToken,
                address(vaultGateway),
                _loss
            );
            vaultGateway.receiveLoss(_pos._collateralToken, _loss);
        }
        _info._realizedTradeProfit += _posFundInfo._tradeProfit;

        if (_posFundInfo._profit > 0) {
            SafeToken.safeTransfer(
                _pos._collateralToken,
                msg.sender,
                uint256(_posFundInfo._profit)
            );
        } else {
            _remainCollateralTokenAmount =
                _remainCollateralTokenAmount -
                uint256(-_posFundInfo._profit);
        }

        SafeToken.safeApprove(
            _pos._collateralToken,
            address(feeReceiver),
            _posFundInfo._rolloverFee + _posFundInfo._closeFee
        );
        feeReceiver.receiveFee(
            _pos._collateralToken,
            _posFundInfo._rolloverFee + _posFundInfo._closeFee
        );

        if (_posFundInfo._fundingFee >= 0) {
            SafeToken.safeApprove(
                _pos._collateralToken,
                address(feeReceiver),
                uint256(_posFundInfo._fundingFee)
            );
            feeReceiver.receiveFee(
                _pos._collateralToken,
                uint256(_posFundInfo._fundingFee)
            );
        } else {
            feeReceiver.sendFee(
                _pos._collateralToken,
                address(this),
                uint256(-_posFundInfo._fundingFee)
            );
        }

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
