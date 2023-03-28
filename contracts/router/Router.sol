// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracleGetter} from "../interface/IPriceOracleGetter.sol";
import {IPlatformToken} from "../interface/IPlatformToken.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IWeth} from "../interface/IWeth.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

// WBTC/WETH/LINK... Router
contract Router is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    uint256 private longFactor1_; // A1 / P1 + ... + An / Pn
    uint256 private longFactor2_; // A1+A2+..+An
    uint256 private shortFactor1_; // // A1 / P1 + ... + An / Pn
    uint256 private shortFactor2_; // A1+A2+.._An
    IPriceOracleGetter public priceOracle;
    address public token;
    mapping(address => bool) public supportTokensToOpen;
    mapping(address => Position) public positions;
    IVaultGateway public vaultGateway;
    address public weth;
    IPlatformToken public platformToken;
    uint256 public FACTOR_MULTIPLIER;

    struct Position {
        uint256 _openPrice;
        address _tokenToOpen; // used which token to open position
        uint256 _tokenToOpenAmount; // amount of collateral
        uint256 _platformTokenAmount; // position size. closed pos will be 0
        bool _isLong;
    }

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "VaultGateway::onlyEOA:: not eoa");
        _;
    }

    function initialize(
        address _priceOracle,
        address _token,
        address[] memory _supportTokensToOpen,
        address _vaultGateway,
        address _weth,
        address _platformToken
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracleGetter(_priceOracle);
        token = _token;
        for (uint256 i = 0; i < _supportTokensToOpen.length; i++) {
            supportTokensToOpen[_supportTokensToOpen[i]] = true;
        }
        vaultGateway = IVaultGateway(_vaultGateway);
        weth = _weth;
        platformToken = IPlatformToken(_platformToken);
        FACTOR_MULTIPLIER = 10 ** 18;
    }

    // amount of platform token by long
    function totalLongFloat() external view returns (uint256, bool) {
        uint256 _tokenPrice = priceOracle.getAssetPrice(token);
        require(_tokenPrice > 0, "Router::totalLongFloat: bad token price");
        if (_tokenPrice * longFactor1_ > longFactor2_) {
            return (
                (_tokenPrice * longFactor1_ - longFactor2_) / FACTOR_MULTIPLIER,
                true
            );
        } else {
            return (
                (longFactor2_ - _tokenPrice * longFactor1_) / FACTOR_MULTIPLIER,
                false
            );
        }
    }

    // amount of platform token by short
    function totalShortFloat() external view returns (uint256, bool) {
        uint256 _tokenPrice = priceOracle.getAssetPrice(token);
        require(_tokenPrice > 0, "Router::totalShortFloat: bad token price");
        if (shortFactor2_ > _tokenPrice * shortFactor1_) {
            return (
                (shortFactor2_ - _tokenPrice * shortFactor1_) /
                    FACTOR_MULTIPLIER,
                true
            );
        } else {
            return (
                (_tokenPrice * shortFactor1_ - shortFactor2_) /
                    FACTOR_MULTIPLIER,
                false
            );
        }
    }

    function openPosition(
        address _tokenToOpen,
        uint256 _platformTokenAmount,
        bool _isLong,
        uint256 _minOrMaxPrice
    ) external payable onlyEOA nonReentrant {
        if (_tokenToOpen == address(0)) {
            require(msg.value > 0, "Router::openPosition: bad msg.value");
            IWeth(weth).depositTo{value: msg.value}(msg.sender);
            _tokenToOpen = weth;
        }
        require(
            supportTokensToOpen[_tokenToOpen],
            "Router::openPosition: not support this token"
        );
        uint256 _tokenPrice = priceOracle.getAssetPrice(token);
        require(_tokenPrice > 0, "Router::openPosition: bad token price");
        uint256 _tokenToOpenPrice = priceOracle.getAssetPrice(_tokenToOpen);
        require(
            _tokenToOpenPrice > 0,
            "Router::openPosition: bad _tokenToOpenPrice price"
        );
        // transfer in _tokenToOpen
        uint256 _platformTokenPrice = vaultGateway.platformTokenPrice();
        require(
            _platformTokenPrice > 0,
            "Router::openPosition: bad _platformTokenPrice price"
        );
        uint256 _needTokenToOpenAmount = (_platformTokenPrice *
            _platformTokenAmount *
            (10 ** IERC20MetadataUpgradeable(_tokenToOpen).decimals())) /
            (_tokenToOpenPrice * (10 ** 8));
        SafeToken.safeTransferFrom(
            _tokenToOpen,
            msg.sender,
            address(this),
            _needTokenToOpenAmount
        );
        // check slippage and modify factors
        if (_isLong) {
            require(
                _tokenPrice <= _minOrMaxPrice,
                "Router::openPosition: can not be larger than _minOrMaxPrice"
            );
            longFactor1_ =
                longFactor1_ +
                (_platformTokenAmount * (10 ** 8) * FACTOR_MULTIPLIER) /
                (_tokenPrice *
                    (10 **
                        IERC20MetadataUpgradeable(platformToken).decimals()));
            longFactor2_ =
                (longFactor2_ + _platformTokenAmount) *
                FACTOR_MULTIPLIER;
        } else {
            require(
                _tokenPrice >= _minOrMaxPrice,
                "Router::openPosition: must be larger than _minOrMaxPrice"
            );
            shortFactor1_ =
                shortFactor1_ +
                (_platformTokenAmount * (10 ** 8) * FACTOR_MULTIPLIER) /
                (_tokenPrice *
                    (10 **
                        IERC20MetadataUpgradeable(platformToken).decimals()));
            shortFactor2_ =
                (shortFactor2_ + _platformTokenAmount) *
                FACTOR_MULTIPLIER;
        }

        // save position
        Position storage pos = positions[msg.sender];
        if (pos._platformTokenAmount == 0) {
            pos._openPrice = _tokenPrice;
            pos._platformTokenAmount = _platformTokenAmount;
            pos._tokenToOpen = _tokenToOpen;
            pos._tokenToOpenAmount = _needTokenToOpenAmount;
            pos._isLong = _isLong;
        } else {
            if ((pos._isLong && _isLong) || (!pos._isLong && !_isLong)) {
                // combine pos
                pos._openPrice =
                    (pos._openPrice *
                        _tokenPrice *
                        (pos._platformTokenAmount + _platformTokenAmount)) /
                    (pos._openPrice *
                        _platformTokenAmount +
                        _tokenPrice *
                        pos._platformTokenAmount);
                pos._platformTokenAmount =
                    pos._platformTokenAmount +
                    _platformTokenAmount;
                pos._tokenToOpenAmount =
                    pos._tokenToOpenAmount +
                    _needTokenToOpenAmount;
            } else {
                _closePosition(
                    msg.sender,
                    _platformTokenAmount,
                    _tokenPrice,
                    _platformTokenPrice,
                    _tokenToOpenPrice,
                    _needTokenToOpenAmount
                );
            }
        }
    }

    function _closePosition(
        address _addr,
        uint256 _platformTokenAmount,
        uint256 _tokenPrice,
        uint256 _platformTokenPrice,
        uint256 _tokenToOpenPrice,
        uint256 _tokenToOpenAmount
    ) private {
        Position storage pos = positions[_addr];
        pos._tokenToOpenAmount = pos._tokenToOpenAmount + _tokenToOpenAmount;
        uint256 _needClosePlatformTokenAmount = 0;
        if (pos._platformTokenAmount >= _platformTokenAmount) {
            _needClosePlatformTokenAmount = _platformTokenAmount;
        } else {
            _needClosePlatformTokenAmount = pos._platformTokenAmount;
            pos._isLong = !pos._isLong;
            pos._openPrice = _tokenPrice;
        }
        pos._platformTokenAmount =
            pos._platformTokenAmount -
            _needClosePlatformTokenAmount;
        uint256 _profit = 0;
        uint256 _loss = 0;
        if (pos._isLong) {
            if (_tokenPrice >= pos._openPrice) {
                _profit =
                    (_tokenPrice * _needClosePlatformTokenAmount) /
                    pos._openPrice -
                    _needClosePlatformTokenAmount;
            } else {
                _loss =
                    _needClosePlatformTokenAmount -
                    (_tokenPrice * _needClosePlatformTokenAmount) /
                    pos._openPrice;
            }
        } else {
            if (pos._openPrice >= _tokenPrice) {
                _profit =
                    _needClosePlatformTokenAmount -
                    (_tokenPrice * _needClosePlatformTokenAmount) /
                    pos._openPrice;
            } else {
                _loss =
                    (_tokenPrice * _needClosePlatformTokenAmount) /
                    pos._openPrice -
                    _needClosePlatformTokenAmount;
            }
        }

        if (_profit > 0) {
            vaultGateway.mintPlatformToken(msg.sender, _profit);
        } else if (_loss > 0) {
            uint256 _needTokenToOpenAmount = (_platformTokenPrice *
                _loss *
                (10 **
                    IERC20MetadataUpgradeable(pos._tokenToOpen).decimals())) /
                (_tokenToOpenPrice * (10 ** 8));
            require(
                pos._tokenToOpenAmount >= _needTokenToOpenAmount,
                "Router::_closePosition: collateral is not enough"
            );
            pos._tokenToOpenAmount =
                pos._tokenToOpenAmount -
                _needTokenToOpenAmount;
            IERC20MetadataUpgradeable(pos._tokenToOpen).approve(
                address(vaultGateway),
                _needTokenToOpenAmount
            );
            vaultGateway.receiveLoss(pos._tokenToOpen, _needTokenToOpenAmount);
        }
    }

    function closePosition(
        uint256 _minOrMaxPrice
    ) external onlyEOA nonReentrant {
        Position storage pos = positions[msg.sender];
        require(pos._platformTokenAmount > 0, "Router::closePosition: bad pos");
        uint256 _tokenPrice = priceOracle.getAssetPrice(token);
        require(_tokenPrice > 0, "Router::closePosition: bad token price");
        uint256 _tokenToOpenPrice = priceOracle.getAssetPrice(pos._tokenToOpen);
        require(
            _tokenToOpenPrice > 0,
            "Router::closePosition: bad _tokenToOpenPrice price"
        );
        // transfer in _tokenToOpen
        uint256 _platformTokenPrice = vaultGateway.platformTokenPrice();
        require(
            _platformTokenPrice > 0,
            "Router::closePosition: bad _platformTokenPrice price"
        );
        if (!pos._isLong) {
            require(
                _tokenPrice <= _minOrMaxPrice,
                "Router::closePosition: can not be larger than _minOrMaxPrice"
            );
        } else {
            require(
                _tokenPrice >= _minOrMaxPrice,
                "Router::closePosition: must be larger than _minOrMaxPrice"
            );
        }
        _closePosition(
            msg.sender,
            pos._platformTokenAmount,
            _tokenPrice,
            _platformTokenPrice,
            _tokenToOpenPrice,
            0
        );
    }
}
