// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract MultiSign is ReentrancyGuardUpgradeable, OwnableUpgradeable {
    event Execution(uint256 indexed transactionId);
    event Submission(uint256 indexed transactionId);

    struct Transaction {
        address destination;
        uint256 value;
        bytes data;
        bool executed;
    }

    uint256 public required;
    address[] public owners;
    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmations;
    uint256 public transactionCount;

    function initialize(
        address[] calldata _owners,
        uint256 _required
    ) external initializer {
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        OwnableUpgradeable.__Ownable_init();
        owners = _owners;
        required = _required;
    }

    function changeOwners (
        address[] calldata _owners,
        uint256 _required
    ) external onlyOwner {
        owners = _owners;
        required = _required;
    }

    receive() external payable {}

    function submitTransaction(
        address _destination,
        uint256 _value,
        bytes calldata _data
    ) external nonReentrant {
        uint256 transactionId = transactionCount;
        transactions[transactionId] = Transaction({
            destination: _destination,
            value: _value,
            data: _data,
            executed: false
        });
        transactionCount += 1;
        _confirmTransaction(transactionId);
        emit Submission(transactionId);
    }

    function confirmTransaction(uint256 _transactionId) external nonReentrant {
        _confirmTransaction(_transactionId);
    }

    function _confirmTransaction(uint256 _transactionId) private {
        require(
            isOwner(msg.sender),
            "MultiSign::confirmTransaction: not owner"
        );
        require(
            transactions[_transactionId].destination != address(0),
            "MultiSign::confirmTransaction: destination is null"
        );
        require(
            !transactions[_transactionId].executed,
            "MultiSign::confirmTransaction: executed already"
        );
        require(
            !confirmations[_transactionId][msg.sender],
            "MultiSign::confirmTransaction: you had confirmed"
        );
        confirmations[_transactionId][msg.sender] = true;
        if (isConfirmed(_transactionId)) {
            Transaction storage txn = transactions[_transactionId];
            txn.executed = true;
            (bool sent, ) = txn.destination.call{value: txn.value}(txn.data);
            require(sent, "MultiSign::confirmTransaction: execute failed");
            emit Execution(_transactionId);
        }
    }

    function isConfirmed(
        uint256 _transactionId
    ) public view returns (bool _isConfirmed) {
        uint256 count = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            if (confirmations[_transactionId][owners[i]]) {
                count += 1;
            }
            if (count == required) {
                return true;
            }
        }
    }

    function isOwner(address _addr) public view returns (bool _isOwner) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == _addr) {
                return true;
            }
        }
    }
}
