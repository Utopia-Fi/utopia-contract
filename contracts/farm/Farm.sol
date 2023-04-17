// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";

contract Farm is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        address fundedBy;
    }

    struct PoolInfo {
        address stakeToken;
        uint256 allocPoint;
        uint256 lastRewardTimestamp;
        uint256 accTokenPerShare;
        uint256 outFee; // ? / 10000
        uint256 noOutFeeTimestamp;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint;
    uint256 public tokenPerSecond;
    IERC20MetadataUpgradeable public token;
    uint256 constant MAXOUTFEE = 50;
    address public foundation;
    uint256 public harvestFee; // ? / 10000
    uint256 public tokenInPool;

    function initialize(
        address _token,
        uint256 _tokenPerSecond,
        address _foundation
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        token = IERC20MetadataUpgradeable(_token);
        tokenPerSecond = _tokenPerSecond;
        foundation = _foundation;
    }

    function pendingToken(
        uint256 _pid,
        address _user
    ) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = IERC20MetadataUpgradeable(pool.stakeToken).balanceOf(
            address(this)
        );
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            uint256 tokenReward = ((block.timestamp -
                pool.lastRewardTimestamp) *
                tokenPerSecond *
                pool.allocPoint) / totalAllocPoint;
            accTokenPerShare =
                accTokenPerShare +
                (tokenReward * 1e12) /
                lpSupply;
        }
        return (user.amount * accTokenPerShare) / 1e12 - user.rewardDebt;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function _harvest(address _to, uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];
        require(user.amount > 0, "Farm::_harvest: nothing to harvest");
        uint256 pending = (user.amount * pool.accTokenPerShare) /
            1e12 -
            user.rewardDebt;
        require(
            pending <= token.balanceOf(address(this)),
            "Farm::_harvest: not enough token"
        );
        uint256 fee = (pending * harvestFee) / 10000;
        if (fee > 0) {
            _safeTokenTransfer(foundation, fee);
        }
        _safeTokenTransfer(_to, pending - fee);
        emit Harvest(_to, _pid, pending);
    }

    function _safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        if (_amount > tokenBal) {
            token.transfer(_to, tokenBal);
        } else {
            token.transfer(_to, _amount);
        }
    }

    function _withdraw(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.fundedBy == msg.sender, "Farm::_withdraw: only funder");
        require(user.amount >= _amount, "Farm::_withdraw: not good");
        updatePool(_pid);
        _harvest(msg.sender, _pid);
        user.amount = user.amount - _amount;
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        if (user.amount == 0) {
            user.fundedBy = address(0);
        }
        if (pool.stakeToken != address(0)) {
            uint256 outFee = pool.outFee;
            if (block.timestamp > pool.noOutFeeTimestamp) {
                outFee = 0;
            }
            uint256 fee = (_amount * outFee) / 10000;
            if (fee > 0) {
                SafeToken.safeTransfer(pool.stakeToken, foundation, fee);
            }
            SafeToken.safeTransfer(
                pool.stakeToken,
                address(msg.sender),
                _amount - fee
            );
            if (pool.stakeToken == address(token)) {
                tokenInPool = tokenInPool - _amount;
            }
        }
        emit Withdraw(msg.sender, _pid, user.amount);
    }

    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.fundedBy != address(0)) {
            require(user.fundedBy == msg.sender, "Pool::deposit:: bad funder");
        }
        require(
            pool.stakeToken != address(0),
            "Pool::deposit:: not accept deposit token"
        );
        updatePool(_pid);
        if (user.amount > 0) {
            _harvest(msg.sender, _pid);
        }
        if (user.fundedBy == address(0)) {
            user.fundedBy = msg.sender;
        }
        SafeToken.safeTransferFrom(
            pool.stakeToken,
            address(msg.sender),
            address(this),
            _amount
        );
        if (pool.stakeToken == address(token)) {
            tokenInPool = tokenInPool + _amount;
        }
        user.amount = user.amount + _amount;
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        _withdraw(_pid, _amount);
    }

    function withdrawAll(uint256 _pid) external nonReentrant {
        _withdraw(_pid, userInfo[_pid][msg.sender].amount);
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(
            user.fundedBy == msg.sender,
            "Farm::emergencyWithdraw: only funder"
        );
        SafeToken.safeTransfer(
            pool.stakeToken,
            address(msg.sender),
            user.amount
        );
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.fundedBy = address(0);
    }

    function harvest(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        _harvest(msg.sender, _pid);
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
    }

    function setPool(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _outFee,
        uint256 _noOutFeeTimestamp
    ) external onlyOwner {
        massUpdatePools();
        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].outFee = _outFee;
        poolInfo[_pid].noOutFeeTimestamp = _noOutFeeTimestamp;
    }

    function setGovAddr(address _gov) external onlyOwner {
        foundation = _gov;
    }

    function isDuplicatedPool(address _stakeToken) public view returns (bool) {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            if (poolInfo[_pid].stakeToken == _stakeToken) {
                return true;
            }
        }
        return false;
    }

    function addPool(
        uint256 _allocPoint,
        address _stakeToken,
        uint256 _outFee,
        uint256 _noOutFeeTimestamp,
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        require(
            _stakeToken != address(0),
            "Farm::addPool: not stakeToken addr"
        );
        require(
            !isDuplicatedPool(_stakeToken),
            "Farm::addPool: stakeToken dup"
        );
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(
            PoolInfo({
                stakeToken: _stakeToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: block.timestamp,
                accTokenPerShare: 0,
                outFee: _outFee,
                noOutFeeTimestamp: _noOutFeeTimestamp
            })
        );
    }

    function setTokenPerSecond(uint256 _tokenPerSecond) external onlyOwner {
        tokenPerSecond = _tokenPerSecond;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = IERC20MetadataUpgradeable(pool.stakeToken).balanceOf(
            address(this)
        );
        if (lpSupply == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 tokenReward = ((block.timestamp - pool.lastRewardTimestamp) *
            tokenPerSecond *
            pool.allocPoint) / totalAllocPoint;
        pool.accTokenPerShare =
            pool.accTokenPerShare +
            (tokenReward * 1e12) /
            lpSupply;
        pool.lastRewardTimestamp = block.timestamp;
    }
}
