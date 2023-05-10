// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

contract WETH is OwnableUpgradeable {
    string public name;
    string public symbol;
    uint8 constant public decimals = 18;
    uint256 constant MAX_INT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    event  Approval(address indexed src, address indexed guy, uint wad);
    event  Transfer(address indexed src, address indexed dst, uint wad);
    event  Deposit(address indexed dst, uint wad);
    event  Withdrawal(address indexed src, uint wad);

    mapping (address => uint)                       public  balanceOf;
    mapping (address => mapping (address => uint))  public  allowance;


    function initialize(
        string memory _name,
        string memory _symbol
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        
        name = _name;
        symbol = _symbol;
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 _amount) external {
        require(balanceOf[msg.sender] >= _amount, "WETH::withdraw: balance not enough");
        balanceOf[msg.sender] -= _amount;
        SafeToken.safeTransferETH(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);
    }

    function totalSupply() external view returns (uint) {
        return address(this).balance;
    }

    function approve(address _to, uint256 _amount) external returns (bool) {
        allowance[msg.sender][_to] = _amount;
        emit Approval(msg.sender, _to, _amount);
        return true;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        return transferFrom(msg.sender, _to, _amount);
    }

    function transferFrom(address _src, address _dst, uint256 _amount)
        public
        returns (bool)
    {
        require(balanceOf[_src] >= _amount, "WETH::transferFrom: balance not enough");

        if (_src != msg.sender && allowance[_src][msg.sender] != MAX_INT) {
            require(allowance[_src][msg.sender] >= _amount, "WETH::transferFrom: allowance not enough");
            allowance[_src][msg.sender] -= _amount;
        }

        balanceOf[_src] -= _amount;
        balanceOf[_dst] += _amount;

        emit Transfer(_src, _dst, _amount);

        return true;
    }
}
