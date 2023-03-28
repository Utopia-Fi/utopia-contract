// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracleGetter} from "../interface/IPriceOracleGetter.sol";
import {IPlatformToken} from "../interface/IPlatformToken.sol";
import {IUniswapUtil} from "../interface/IUniswapUtil.sol";
import {IRouter} from "../interface/IRouter.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

contract VaultGateway is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    event Mint(
        address indexed _user,
        address indexed _tokenToMint,
        uint256 _tokenToMintAmount,
        uint256 _mintedAmount
    );
    event Redeem(
        address indexed _user,
        address indexed _tokenToRedeem,
        uint256 _platformTokenAmount,
        uint256 _redeemedAmount
    );

    IPriceOracleGetter public priceOracle;
    uint256 public initialMintRightPerNft; // platformToken
    mapping(uint256 => uint256) public usedMintRight; // tokenId => platformToken
    IERC721MetadataUpgradeable public nft;
    mapping(address => bool) public supportTokensToMint;
    IPlatformToken public platformToken;
    mapping(address => bool) public supportTokensToRedeem;
    address public usdtAddr;
    uint256 public defaultSlippage; // ?/10000
    IUniswapUtil public uniswapUtil;
    address public weth;
    IRouter[] public routers;

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "VaultGateway::onlyEOA:: not eoa");
        _;
    }

    modifier onlyRouter() {
        bool isRouter = false;
        for (uint256 i = 0; i < routers.length; i++) {
            if (address(routers[i]) == msg.sender) {
                isRouter = true;
            }
        }
        require(isRouter, "VaultGateway::onlyRouter:: not router");
        _;
    }

    function initialize(
        address _priceOracle,
        uint256 _initialMintRightPerNft,
        address _nft,
        address[] memory _supportTokensToMint,
        address[] memory _supportTokensToRedeem,
        address _platformToken,
        address _usdtAddr,
        uint256 _defaultSlippage,
        address _uniswapUtilAddr,
        address _weth
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracleGetter(_priceOracle);
        initialMintRightPerNft = _initialMintRightPerNft;
        nft = IERC721MetadataUpgradeable(_nft);
        for (uint256 i = 0; i < _supportTokensToMint.length; i++) {
            supportTokensToMint[_supportTokensToMint[i]] = true;
        }
        for (uint256 i = 0; i < _supportTokensToRedeem.length; i++) {
            supportTokensToRedeem[_supportTokensToRedeem[i]] = true;
        }
        platformToken = IPlatformToken(_platformToken);
        usdtAddr = _usdtAddr;
        defaultSlippage = _defaultSlippage;
        uniswapUtil = IUniswapUtil(_uniswapUtilAddr);
        weth = _weth;
    }

    function addRouter(address _router) external onlyOwner {
        routers.push(IRouter(_router));
    }

    // USDT/USDC/ETH/ARB
    function mintByNft(
        uint256 _tokenId,
        address _tokenToMint,
        uint256 _tokenToMintAmount,
        uint256 _slippage
    ) external payable onlyEOA nonReentrant {
        // verify nft owner
        require(
            nft.ownerOf(_tokenId) == msg.sender,
            "VaultGateway::mintByNft: must have this nft"
        );
        // verify token to mint
        uint256 _receivedUsdt = 0;
        {
            require(
                _tokenToMint == address(0) || supportTokensToMint[_tokenToMint],
                "VaultGateway::mintByNft: not support this token"
            );
            // receive token and swap to usdt
            uint256 __slippage = _slippage;
            if (__slippage == 0) {
                __slippage = defaultSlippage;
            }
            address __tokenToMint = _tokenToMint;
            uint256 _msgValue = 0;
            if (_tokenToMint == address(0)) {
                require(
                    msg.value == _tokenToMintAmount,
                    "VaultGateway::mintByNft: bad msg.value"
                );
                __tokenToMint = weth;
                _msgValue = _tokenToMintAmount;
            } else {
                SafeToken.safeTransferFrom(
                    _tokenToMint,
                    msg.sender,
                    address(this),
                    _tokenToMintAmount
                );
            }
            uint256 _tokenToMintPrice = priceOracle.getAssetPrice(
                __tokenToMint
            );
            uint256 _toUsd = (_tokenToMintAmount * _tokenToMintPrice) /
                (10 ** IERC20MetadataUpgradeable(__tokenToMint).decimals());
            uint256 _amountOutMinimum = _toUsd -
                (_toUsd * __slippage * 2) /
                10000;
            _receivedUsdt = uniswapUtil.swapExactInput{value: _msgValue}(
                _tokenToMintAmount,
                _amountOutMinimum,
                _tokenToMint,
                usdtAddr,
                3000
            );
        }
        // verify nft usd mint right and mint
        uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
        require(_usdtPrice > 0, "VaultGateway::mintByNft: bad usdt price");
        uint256 _receivedUsd = (_receivedUsdt * _usdtPrice) /
            (10 ** IERC20MetadataUpgradeable(usdtAddr).decimals());

        uint256 _platformTokenPrice = _calcPlatformTokenPrice();
        uint256 _mintAmount = (_receivedUsd *
            (10 ** platformToken.decimals())) / _platformTokenPrice;

        uint256 _remainMintRight = initialMintRightPerNft;
        if (usedMintRight[_tokenId] != 0) {
            _remainMintRight = initialMintRightPerNft - usedMintRight[_tokenId];
        }
        require(
            _mintAmount <= _remainMintRight,
            "VaultGateway::mintByNft: mint right of nft is not enough"
        );
        usedMintRight[_tokenId] = usedMintRight[_tokenId] + _mintAmount;
        platformToken.mint(msg.sender, _mintAmount);
        // emit event
        emit Mint(msg.sender, _tokenToMint, _tokenToMintAmount, _mintAmount);
    }

    function platformTokenPrice() external view returns (uint256) {
        return _calcPlatformTokenPrice();
    }

    function mintPlatformToken(
        address _account,
        uint256 _amount
    ) external onlyRouter {
        platformToken.mint(_account, _amount);
    }

    function receiveLoss(address _token, uint256 _amount) external onlyRouter {
        // fetch token
        SafeToken.safeTransferFrom(_token, msg.sender, address(this), _amount);
        // swap to usdt
        _swapToUsdt(_token, _amount, defaultSlippage);
    }

    function _swapToUsdt(
        address _token,
        uint256 _amount,
        uint256 _slippage
    ) private returns (uint256) {
        uint256 _tokenPrice = priceOracle.getAssetPrice(_token);
        uint256 _toUsd = (_amount * _tokenPrice) /
            (10 ** IERC20MetadataUpgradeable(_token).decimals());
        uint256 _amountOutMinimum = _toUsd - (_toUsd * _slippage * 2) / 10000;
        return
            uniswapUtil.swapExactInput(
                _amount,
                _amountOutMinimum,
                _token,
                usdtAddr,
                3000
            );
    }

    // usd per platform token
    function _calcPlatformTokenPrice() private view returns (uint256) {
        // TODO
        uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
        require(
            _usdtPrice > 0,
            "VaultGateway::_calcPlatformTokenPrice: bad usdt price"
        );
        uint256 platformTokenTotal = platformToken.totalSupply();
        for (uint256 i = 0; i < routers.length; i++) {
            (uint256 _vLong, bool _bLong) = routers[i].totalLongFloat();
            if (!_bLong) {
                platformTokenTotal = platformTokenTotal + _vLong;
            } else {
                require(
                    platformTokenTotal >= _vLong,
                    "VaultGateway::_calcPlatformTokenPrice: platformTokenTotal not enough"
                );
                platformTokenTotal = platformTokenTotal - _vLong;
            }
            (uint256 _vShort, bool _bShort) = routers[i].totalShortFloat();
            if (!_bShort) {
                platformTokenTotal = platformTokenTotal + _vShort;
            } else {
                require(
                    platformTokenTotal >= _vShort,
                    "VaultGateway::_calcPlatformTokenPrice: platformTokenTotal not enough"
                );
                platformTokenTotal = platformTokenTotal - _vShort;
            }
        }
        return
            (_usdtPrice *
                SafeToken.myBalance(usdtAddr) *
                platformToken.decimals()) /
            (platformTokenTotal *
                (10 ** IERC20MetadataUpgradeable(usdtAddr).decimals()));
    }

    function redeem(
        uint256 _platformTokenAmount,
        address _tokenToRedeem
    ) external onlyEOA nonReentrant {
        // verify token to mint
        require(
            supportTokensToRedeem[_tokenToRedeem],
            "VaultGateway::redeem: not support this token"
        );
        // burn token
        platformToken.burn(msg.sender, _platformTokenAmount);
        // send _tokenToRedeem
        uint256 _platformTokenPrice = _calcPlatformTokenPrice();
        uint256 _tokenToRedeemPrice = priceOracle.getAssetPrice(_tokenToRedeem);
        require(
            _tokenToRedeemPrice > 0,
            "VaultGateway::redeem: bad token redeem price"
        );
        uint256 _tokenToRedeemAmount = ((_platformTokenAmount *
            _platformTokenPrice *
            (10 ** IERC20MetadataUpgradeable(_tokenToRedeem).decimals())) /
            _tokenToRedeemPrice) * (10 ** platformToken.decimals());
        SafeToken.safeTransfer(
            _tokenToRedeem,
            msg.sender,
            _tokenToRedeemAmount
        );
        // emit event
        emit Redeem(
            msg.sender,
            _tokenToRedeem,
            _platformTokenAmount,
            _tokenToRedeemAmount
        );
    }
}
