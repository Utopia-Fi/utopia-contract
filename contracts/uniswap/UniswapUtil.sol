// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IWeth} from "../interface/IWeth.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

contract UniswapUtil is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    ISwapRouter public swapRouter;
    IWeth public weth;

    function initialize(
        address _swapRouterAddr,
        address _weth
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        swapRouter = ISwapRouter(_swapRouterAddr);
        weth = IWeth(_weth);
    }

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
            weth.deposit{value: msg.value}();
        } else {
            TransferHelper.safeTransferFrom(
                __tokenIn,
                msg.sender,
                address(this),
                _amountIn
            );
        }

        TransferHelper.safeApprove(__tokenIn, address(swapRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: __tokenIn,
                tokenOut: _tokenOut,
                fee: uint24(_poolFee),
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: _amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        _amountOut = swapRouter.exactInputSingle(params);
    }

    function swapExactOutput(
        uint256 _amountOut,
        uint256 _amountInMaximum,
        address _tokenIn,
        address _tokenOut,
        uint256 _poolFee
    ) external nonReentrant returns (uint256 _amountIn) {
        TransferHelper.safeTransferFrom(
            _tokenIn,
            msg.sender,
            address(this),
            _amountInMaximum
        );

        TransferHelper.safeApprove(
            _tokenIn,
            address(swapRouter),
            _amountInMaximum
        );

        IERC20MetadataUpgradeable __tokenIn = IERC20MetadataUpgradeable(
            _tokenOut
        );
        if (_tokenOut == address(0)) {
            __tokenIn = IERC20MetadataUpgradeable(address(weth));
        }
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
            .ExactOutputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: address(__tokenIn),
                fee: uint24(_poolFee),
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: _amountOut,
                amountInMaximum: _amountInMaximum,
                sqrtPriceLimitX96: 0
            });
        uint256 _tokenOutBalBefore = __tokenIn.balanceOf(address(this));
        _amountIn = swapRouter.exactOutputSingle(params);
        require(
            _amountIn < _amountInMaximum,
            "UniswapUtil::swapExactOutputSingle: greater than amountInMaximum"
        );
        uint256 _tokenOutBalAfter = __tokenIn.balanceOf(address(this));
        if (_tokenOut == address(0)) {
            weth.withdrawTo(msg.sender, _tokenOutBalAfter - _tokenOutBalBefore);
        } else {
            TransferHelper.safeTransfer(
                _tokenOut,
                msg.sender,
                _tokenOutBalAfter - _tokenOutBalBefore
            );
        }

        TransferHelper.safeApprove(_tokenIn, address(swapRouter), 0);
        TransferHelper.safeTransfer(
            _tokenIn,
            msg.sender,
            _amountInMaximum - _amountIn
        );
    }
}
