// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IWeth} from "../../interface/IWeth.sol";
import {SafeToken} from "../../util/SafeToken.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IPriceOracle} from "../../interface/IPriceOracle.sol";

contract UniswapUtilTestnet is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    IPriceOracle public priceOracle;
    IWeth public weth;

    function initialize(
        address _priceOracle,
        address _weth
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        priceOracle = IPriceOracle(_priceOracle);
        weth = IWeth(_weth);
    }

    receive() external payable {}

    function swapExactInput(
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        address _tokenIn,
        address _tokenOut,
        uint256 _poolFee
    ) external payable nonReentrant returns (uint256 _amountOut) {
        address __tokenIn = _tokenIn;
        if (_tokenIn == address(0)) {
            __tokenIn = address(weth);
            require(
                msg.value == _amountIn,
                "UniswapUtil::swapExactInput: bad msg.value"
            );
        } else {
            SafeToken.safeTransferFrom(
                __tokenIn,
                msg.sender,
                address(this),
                _amountIn
            );
        }
        uint256 _tokenInPrice = priceOracle.getAssetPrice(__tokenIn);
        require(
            _tokenInPrice > 0,
            "UniswapUtil::swapExactInput: bad _tokenInPrice price"
        );

        address __tokenOut = _tokenOut;
        if (_tokenOut == address(0)) {
            __tokenOut = address(weth);
        }
        uint256 _tokenOutPrice = priceOracle.getAssetPrice(__tokenOut);
        require(
            _tokenOutPrice > 0,
            "UniswapUtil::swapExactInput: bad _tokenOutPrice price"
        );

        _amountOut =
            (_amountIn *
                _tokenInPrice *
                (10 ** IERC20MetadataUpgradeable(__tokenOut).decimals())) /
            _tokenOutPrice /
            (10 ** IERC20MetadataUpgradeable(__tokenIn).decimals());
        if (_tokenOut == address(0)) {
            SafeToken.safeTransferETH(msg.sender, _amountOut);
        } else {
            SafeToken.safeTransfer(__tokenOut, msg.sender, _amountOut);
        }
    }

    function swapExactOutput(
        uint256 _amountOut,
        uint256 _amountInMaximum,
        address _tokenIn,
        address _tokenOut,
        uint256 _poolFee
    ) external payable nonReentrant returns (uint256 _amountIn) {
        address __tokenIn = _tokenIn;
        if (_tokenIn == address(0)) {
            __tokenIn = address(weth);
        }
        uint256 _tokenInPrice = priceOracle.getAssetPrice(__tokenIn);
        require(
            _tokenInPrice > 0,
            "UniswapUtil::swapExactInput: bad _tokenInPrice price"
        );

        address __tokenOut = _tokenOut;
        if (_tokenOut == address(0)) {
            __tokenOut = address(weth);
        }
        uint256 _tokenOutPrice = priceOracle.getAssetPrice(__tokenOut);
        require(
            _tokenOutPrice > 0,
            "UniswapUtil::swapExactInput: bad _tokenOutPrice price"
        );

        _amountIn =
            (_amountOut *
                _tokenOutPrice *
                (10 ** IERC20MetadataUpgradeable(__tokenIn).decimals())) /
            _tokenInPrice /
            (10 ** IERC20MetadataUpgradeable(__tokenOut).decimals());
        if (_tokenIn == address(0)) {
            SafeToken.safeTransferETH(msg.sender, msg.value - _amountIn);
        } else {
            SafeToken.safeTransferFrom(
                __tokenIn,
                msg.sender,
                address(this),
                _amountIn
            );
        }
        if (_tokenOut == address(0)) {
            SafeToken.safeTransferETH(msg.sender, _amountOut);
        } else {
            SafeToken.safeTransfer(__tokenOut, msg.sender, _amountOut);
        }
    }
}
