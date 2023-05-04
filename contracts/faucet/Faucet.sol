
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

struct TokenInfo {
    address _token;
    uint256 _amount;
}

contract Faucet is OwnableUpgradeable {

    address[] public tokens;
    mapping(address => TokenInfo) public tokenInfos;
    address public sender;

    function initialize(
        TokenInfo[] memory _tokenInfos,
        address _sender
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();

        for (uint256 i = 0; i < _tokenInfos.length; i++) {
            tokenInfos[
                _tokenInfos[i]._token
            ] = _tokenInfos[i];
            tokens.push(_tokenInfos[i]._token);
        }
        sender = _sender;
    }

    receive() external payable {}

    modifier onlySenderOrOwner {
        require(sender == msg.sender || owner() == msg.sender, "Faucet::onlySender: not sender and not owner");
        _;
    }

    function changeTokenInfos(TokenInfo[] memory _tokenInfos) external onlyOwner {
        for (uint256 i = 0; i < _tokenInfos.length; i++) {
            tokenInfos[
                _tokenInfos[i]._token
            ] = _tokenInfos[i];
            tokens.push(_tokenInfos[i]._token);
        }
    }

    function send(address _target) external onlySenderOrOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenInfo memory _tokenInfo = tokenInfos[tokens[i]];
            if (_tokenInfo._token == address(0)) {
                SafeToken.safeTransferETH(_target, _tokenInfo._amount);
            } else {
                SafeToken.safeTransfer(_tokenInfo._token, _target, _tokenInfo._amount);
            }
        }
    }
}
