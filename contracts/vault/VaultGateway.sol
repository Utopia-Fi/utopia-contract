// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracle} from "../interface/IPriceOracle.sol";
import {IUtopiaToken} from "../interface/IUtopiaToken.sol";
import {IUniswapUtil} from "../interface/IUniswapUtil.sol";
import {IVaultGateway} from "../interface/IVaultGateway.sol";
import {IRouter} from "../interface/IRouter.sol";
import {IWeth} from "../interface/IWeth.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";
import {IInviteManager} from "../interface/IInviteManager.sol";

contract VaultGateway is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IVaultGateway
{
    event Mint(
        address indexed _user,
        address indexed _tokenToMint,
        uint256 _tokenToMintAmount,
        uint256 _mintedAmount
    );
    event Redeem(
        address indexed _user,
        address indexed _tokenToRedeem,
        uint256 _utopiaTokenAmount,
        uint256 _redeemedAmount,
        uint256 _redeemFee
    );

    IPriceOracle public priceOracle;
    mapping(address => bool) public supportTokensToMint;
    IUtopiaToken public override utopiaToken;
    mapping(address => bool) public supportTokensToRedeem;
    address public usdtAddr;
    uint256 public defaultSlippage; // ?/10000
    IUniswapUtil public uniswapUtil;
    address public weth;
    IRouter[] public routers;
    uint256 public redeemFeeRate; // ?/10000
    uint256 public redeemableTime;
    uint256 public constant maxSlippage = 5000;
    IInviteManager public inviteManager;

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
        address[] memory _supportTokensToMint,
        address[] memory _supportTokensToRedeem,
        address _utopiaToken,
        address _usdtAddr,
        uint256 _defaultSlippage,
        address _uniswapUtilAddr,
        address _weth,
        uint256 _redeemFeeRate,
        address _inviteManager
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        priceOracle = IPriceOracle(_priceOracle);
        for (uint256 i = 0; i < _supportTokensToMint.length; i++) {
            supportTokensToMint[_supportTokensToMint[i]] = true;
        }
        for (uint256 i = 0; i < _supportTokensToRedeem.length; i++) {
            supportTokensToRedeem[_supportTokensToRedeem[i]] = true;
        }
        utopiaToken = IUtopiaToken(_utopiaToken);
        usdtAddr = _usdtAddr;
        defaultSlippage = _defaultSlippage;
        uniswapUtil = IUniswapUtil(_uniswapUtilAddr);
        weth = _weth;
        redeemFeeRate = _redeemFeeRate;
        redeemableTime = block.timestamp;
        inviteManager = IInviteManager(_inviteManager);
    }

    function listRouters() external view returns (IRouter[] memory) {
        return routers;
    }

    function changeSupportTokensToMint(address[] memory _supportTokensToMint) external onlyOwner {
        for (uint256 i = 0; i < _supportTokensToMint.length; i++) {
            supportTokensToMint[_supportTokensToMint[i]] = true;
        }
    }

    function changeInviteManager(address _inviteManager) external onlyOwner {
        inviteManager = IInviteManager(_inviteManager);
    }

    function changeUniswapUtil(address _uniswapUtil) external onlyOwner {
        uniswapUtil = IUniswapUtil(_uniswapUtil);
    }

    function changeRedeemFeeRate(uint256 _redeemFeeRate) external onlyOwner {
        redeemFeeRate = _redeemFeeRate;
    }

    function changeDefaultSlippage(
        uint256 _defaultSlippage
    ) external onlyOwner {
        defaultSlippage = _defaultSlippage;
    }

    function changeRedeemableTime(uint256 _redeemableTime) external onlyOwner {
        redeemableTime = _redeemableTime;
    }

    function changeRouters(IRouter[] calldata _routers) external onlyOwner {
        routers = _routers;
    }

    function mintByNftETH(
        uint256 _utopiaTokenAmount,
        uint256 _slippage,
        address _inviter
    ) external payable onlyEOA nonReentrant {
        require(
            _slippage <= maxSlippage,
            "VaultGateway::mintByNftETH: _slippage too large"
        );

        require(
            supportTokensToMint[weth],
            "VaultGateway::mintByNftETH: not support this token"
        );
        uint256 _tokenToMintPrice = priceOracle.getAssetPrice(weth);
        require(
            _tokenToMintPrice > 0,
            "VaultGateway::mintByNftETH: bad _tokenToMintPrice price"
        );
        uint256 _utopiaTokenPrice = _calcUtopiaTokenPrice();
        require(
            _utopiaTokenPrice > 0,
            "VaultGateway::mintByNftETH: bad _utopiaTokenPrice price"
        );

        uint256 _needUsd = (_utopiaTokenAmount * _utopiaTokenPrice) /
            (10 ** IERC20MetadataUpgradeable(utopiaToken).decimals());

        uint256 _needTokenToMintAmount = (_needUsd * (10 ** 18)) /
            _tokenToMintPrice;
        uint256 __slippage = _slippage;
        if (__slippage == 0) {
            __slippage = defaultSlippage;
        }
        uint256 _amountInMaximum = _needTokenToMintAmount +
            (_needTokenToMintAmount * __slippage * 2) /
            10000 +
            (_needTokenToMintAmount * 30 * 2) /
            10000;
        require(
            msg.value >= _amountInMaximum,
            "VaultGateway::mintByNftETH: not enough msg.value"
        );
        utopiaToken.mint(msg.sender, _utopiaTokenAmount);
        if (address(inviteManager) != address(0)) {
            inviteManager.tryInvite(_inviter, msg.sender);
        }

        {
            IWeth(weth).deposit{value: msg.value}();
            SafeToken.safeApprove(weth, address(uniswapUtil), _amountInMaximum);
            uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
            require(
                _usdtPrice > 0,
                "VaultGateway::mintByNftETH: bad _usdtPrice price"
            );
            uint256 _needUsdt = (_needUsd *
                (10 ** IERC20MetadataUpgradeable(usdtAddr).decimals())) /
                _usdtPrice;
            uint256 _spentTokenToMintAmount = uniswapUtil.swapExactOutput(
                _needUsdt,
                _amountInMaximum,
                weth,
                usdtAddr,
                3000
            );
            IWeth(weth).withdrawTo(
                msg.sender,
                msg.value - _spentTokenToMintAmount
            );
            // emit event
            emit Mint(
                msg.sender,
                address(0),
                _spentTokenToMintAmount,
                _utopiaTokenAmount
            );
        }
    }

    function mintByNft(
        address _tokenToMint,
        uint256 _utopiaTokenAmount,
        uint256 _slippage,
        address _inviter
    ) external payable onlyEOA nonReentrant {
        require(
            _slippage <= maxSlippage,
            "VaultGateway::mintByNft: _slippage too large"
        );
        // verify token to mint
        uint256 _spentTokenToMintAmount = 0;
        {
            require(
                supportTokensToMint[_tokenToMint],
                "VaultGateway::mintByNft: not support this token"
            );
            // receive token and swap to usdt
            uint256 _needUsd = (_utopiaTokenAmount * _calcUtopiaTokenPrice()) /
                (10 ** IERC20MetadataUpgradeable(utopiaToken).decimals());

            uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
            require(
                _usdtPrice > 0,
                "VaultGateway::mintByNftETH: bad _usdtPrice price"
            );

            if (_tokenToMint == usdtAddr) {
                SafeToken.safeTransferFrom(
                    _tokenToMint,
                    msg.sender,
                    address(this),
                    (_needUsd *
                        (10 **
                            IERC20MetadataUpgradeable(_tokenToMint)
                                .decimals())) / _usdtPrice
                );
            } else {
                uint256 _tokenToMintPrice = priceOracle.getAssetPrice(
                    _tokenToMint
                );
                require(
                    _tokenToMintPrice > 0,
                    "VaultGateway::mintByNft: bad _tokenToMintPrice price"
                );
                uint256 _needTokenToMintAmount =
                    (_needUsd *
                        (10 **
                            IERC20MetadataUpgradeable(_tokenToMint)
                                .decimals())) /
                    _tokenToMintPrice;
                uint256 __slippage = _slippage;
                if (__slippage == 0) {
                    __slippage = defaultSlippage;
                }
                uint256 _amountInMaximum = _needTokenToMintAmount +
                    (_needTokenToMintAmount * __slippage * 2) /
                    10000 +
                    (_needTokenToMintAmount * 30 * 2) /
                    10000;
                SafeToken.safeTransferFrom(
                    _tokenToMint,
                    msg.sender,
                    address(this),
                    _amountInMaximum
                );
                SafeToken.safeApprove(
                    _tokenToMint,
                    address(uniswapUtil),
                    _amountInMaximum
                );
                uint256 _needUsdt = (_needUsd *
                    (10 ** IERC20MetadataUpgradeable(usdtAddr).decimals())) /
                    _usdtPrice;
                _spentTokenToMintAmount = uniswapUtil.swapExactOutput(
                    _needUsdt,
                    _amountInMaximum,
                    _tokenToMint,
                    usdtAddr,
                    3000
                );
                SafeToken.safeTransfer(
                    _tokenToMint,
                    msg.sender,
                    _amountInMaximum - _spentTokenToMintAmount
                );
            }
        }
        utopiaToken.mint(msg.sender, _utopiaTokenAmount);
        if (address(inviteManager) != address(0)) {
            inviteManager.tryInvite(_inviter, msg.sender);
        }
        // emit event
        emit Mint(
            msg.sender,
            _tokenToMint,
            _spentTokenToMintAmount,
            _utopiaTokenAmount
        );
    }

    function utopiaTokenPrice() external view returns (uint256) {
        return _calcUtopiaTokenPrice();
    }

    function _toUsdt(
        address _token,
        uint256 _tokenAmount
    ) private view returns (uint256) {
        uint256 _tokenPrice = priceOracle.getAssetPrice(_token);
        require(
            _tokenPrice > 0,
            "VaultGateway::_toUsdt: bad _tokenPrice price"
        );
        uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
        require(_usdtPrice > 0, "VaultGateway::_toUsdt: bad _usdtPrice price");
        return
            (_tokenPrice *
                _tokenAmount *
                (10 ** IERC20MetadataUpgradeable(usdtAddr).decimals())) /
            _usdtPrice /
            10 ** IERC20MetadataUpgradeable(_token).decimals();
    }

    function _usdtTo(
        address _token,
        uint256 _usdtAmount
    ) private view returns (uint256) {
        uint256 _tokenPrice = priceOracle.getAssetPrice(_token);
        require(
            _tokenPrice > 0,
            "VaultGateway::_usdtTo: bad _tokenPrice price"
        );
        uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
        require(_usdtPrice > 0, "VaultGateway::_usdtTo: bad _usdtPrice price");
        return
            (_usdtPrice *
                _usdtAmount *
                (10 ** IERC20MetadataUpgradeable(_token).decimals())) /
            _tokenPrice /
            10 ** IERC20MetadataUpgradeable(usdtAddr).decimals();
    }

    function sendProfit(
        address _account,
        address _token,
        uint256 _amount
    ) external onlyRouter {
        // swap
        if (_token != usdtAddr) {
            uint256 _needUsdtAmount = _toUsdt(_token, _amount);
            uint256 _amountInMaximum = _needUsdtAmount +
                (_needUsdtAmount * defaultSlippage * 2) /
                10000 +
                (_needUsdtAmount * 30 * 2) /
                10000;
            uniswapUtil.swapExactOutput(
                _amount,
                _amountInMaximum,
                usdtAddr,
                _token,
                3000
            );
        }
        // send
        SafeToken.safeTransfer(_token, _account, _amount);
    }

    function receiveLoss(address _token, uint256 _amount) external onlyRouter {
        // fetch token
        SafeToken.safeTransferFrom(_token, msg.sender, address(this), _amount);
        // swap to usdt
        if (_token != usdtAddr) {
            uint256 _needUsdtAmount = _toUsdt(_token, _amount);
            uint256 _amountOutMinimum = _needUsdtAmount -
                (_needUsdtAmount * defaultSlippage * 2) /
                10000 -
                (_needUsdtAmount * 30 * 2) /
                10000;
            uniswapUtil.swapExactInput(
                _amount,
                _amountOutMinimum,
                _token,
                usdtAddr,
                3000
            );
        }
    }

    // Usd
    function reserveTotal() public view returns (uint256) {
        uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
        require(_usdtPrice > 0, "VaultGateway::reserveTotal: bad usdt price");
        return
            (_usdtPrice * SafeToken.myBalance(usdtAddr)) /
            (10 ** IERC20MetadataUpgradeable(usdtAddr).decimals());
    }

    // Usd
    function totalTradePairFloat() public view returns (int256) {
        int256 result;
        for (uint256 i = 0; i < routers.length; i++) {
            result = result + routers[i].totalFloat();
        }
        return result;
    }

    // usd per platform token
    function _calcUtopiaTokenPrice() private view returns (uint256) {
        uint256 _reserveTotal = reserveTotal();
        if (_reserveTotal == 0) {
            uint256 _usdtPrice = priceOracle.getAssetPrice(usdtAddr);
            require(
                _usdtPrice > 0,
                "VaultGateway::_calcUtopiaTokenPrice: bad usdt price"
            );
            return _usdtPrice;
        }
        int256 _totalTradePairFloat = totalTradePairFloat();
        if (_totalTradePairFloat >= 0) {
            require(
                _reserveTotal >= uint256(_totalTradePairFloat),
                "VaultGateway::_calcUtopiaTokenPrice: reserve in pool not enough"
            );
            return
                ((_reserveTotal - uint256(_totalTradePairFloat)) *
                    (10 ** utopiaToken.decimals())) / utopiaToken.totalSupply();
        } else {
            return
                ((_reserveTotal + uint256(-_totalTradePairFloat)) *
                    (10 ** utopiaToken.decimals())) / utopiaToken.totalSupply();
        }
    }

    function redeem(
        uint256 _utopiaTokenAmount,
        address _tokenToRedeem
    ) external onlyEOA nonReentrant {
        // check time
        require(
            block.timestamp >= redeemableTime,
            "VaultGateway::redeem: not touch redeemableTime"
        );
        // verify token to mint
        require(
            supportTokensToRedeem[_tokenToRedeem],
            "VaultGateway::redeem: not support this token"
        );
        uint256 _utopiaTokenPrice = _calcUtopiaTokenPrice();
        // burn token
        utopiaToken.burn(msg.sender, _utopiaTokenAmount);
        // send _tokenToRedeem
        uint256 _tokenToRedeemPrice = priceOracle.getAssetPrice(_tokenToRedeem);
        require(
            _tokenToRedeemPrice > 0,
            "VaultGateway::redeem: bad token redeem price"
        );
        uint256 _tokenToRedeemAmount = (_utopiaTokenAmount *
            _utopiaTokenPrice *
            (10 ** IERC20MetadataUpgradeable(_tokenToRedeem).decimals())) /
            _tokenToRedeemPrice /
            10 ** utopiaToken.decimals();

        uint256 _redeemFee = (redeemFeeRate * redeemFeeRate) / 10000;
        uint256 _redeemAmount = _tokenToRedeemAmount - _redeemFee;
        SafeToken.safeTransfer(_tokenToRedeem, msg.sender, _redeemAmount);
        // emit event
        emit Redeem(
            msg.sender,
            _tokenToRedeem,
            _utopiaTokenAmount,
            _redeemAmount,
            _redeemFee
        );
    }
}
