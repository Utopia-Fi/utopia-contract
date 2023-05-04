
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

struct TokenInfo {
    address _token;
    uint256 _amount;
}

contract Faucet is OwnableUpgradeable {

    TokenInfo[] storage public tokenInfos;
    address public sender;

    function initialize(
        TokenInfo[] memory _tokenInfos,
        address _sender
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();

        tokenInfos = _tokenInfos;
        sender = _sender;
    }

    modifier onlySender {
        require(sender == msg.sender, "Faucet::onlySender: not sender");
        _;
    }

    function changeTokenInfos(TokenInfo[] memory _tokenInfos) external onlyOwner {
        tokenInfos = _tokenInfos;
    }

    function send(address _target) external onlySender {
        for (uint256 i = 0; i < tokenInfos.length; i++) {
            TokenInfo memory _tokenInfo = tokenInfos[i];
            if (_tokenInfo._token == address(0)) {
                SafeToken.safeTransferETH(_target, _tokenInfo._amount);
            } else {
                SafeToken.safeTransfer(_tokenInfo._token, _target, _tokenInfo._amount);
            }
        }
    }
}
