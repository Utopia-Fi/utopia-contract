// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {SafeToken} from "../util/SafeToken.sol";
import {IERC721MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import { IERC721ReceiverUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

contract Farm is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    event Deposit(address indexed _user, uint256 indexed _pid, uint256 _amount);
    event DepositNft(address indexed _user, uint256 _tokenId);
    event Withdraw(
        address indexed _user,
        uint256 indexed _pid,
        uint256 _amount
    );
    event Harvest(address indexed _user, uint256 indexed _pid, uint256 _amount);

    struct UserInfo {
        uint256 _amount;
        uint256 _rewardDebt;
        uint256[] _tokenIds;
    }

    struct PoolInfo {
        address _stakeToken;
        uint256 _allocPoint;
        uint256 _lastRewardTimestamp;
        uint256 _accTokenPerShare;
        uint256 _outFee; // ? / 10000
        uint256 _noOutFeeTimestamp;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint;
    uint256 public tokenPerSecond;
    IERC20MetadataUpgradeable public token;
    uint256 constant MAXOUTFEE = 50;
    address public foundation;
    uint256 public harvestFeeRate; // ? / 10000
    uint256 public tokenInPool;

    uint256 public nftBonusRate; // ? / 10000
    IERC721MetadataUpgradeable public utopiaNft;
    uint256 public constant MaxDepositedNum = 10;

    function initialize(
        address _token,
        uint256 _tokenPerSecond,
        address _foundation,
        address _utopiaNft,
        uint256 _nftBonusRate
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        token = IERC20MetadataUpgradeable(_token);
        tokenPerSecond = _tokenPerSecond;
        foundation = _foundation;
        utopiaNft = IERC721MetadataUpgradeable(_utopiaNft);
        nftBonusRate = _nftBonusRate;
    }

    function stakedNfts(
        uint256 _pid,
        address _user
    ) public view returns (uint256[] memory) {
        UserInfo storage _userInfo = userInfo[_pid][_user];
        return _userInfo._tokenIds;
    }

    function pendingToken(
        uint256 _pid,
        address _user
    ) public view returns (uint256) {
        PoolInfo storage _pool = poolInfo[_pid];
        UserInfo storage _userInfo = userInfo[_pid][_user];
        uint256 _accTokenPerShare = _pool._accTokenPerShare;
        uint256 _lpSupply = totalStakeToken(_pid);
        if (block.timestamp > _pool._lastRewardTimestamp && _lpSupply != 0) {
            uint256 _tokenReward = ((block.timestamp -
                _pool._lastRewardTimestamp) *
                tokenPerSecond *
                _pool._allocPoint) / totalAllocPoint;
            _accTokenPerShare += (_tokenReward * 1e12) / _lpSupply;
        }

        return
            (_amountWithNft(_userInfo) * _accTokenPerShare) /
            1e12 -
            _userInfo._rewardDebt;
    }

    function amountWithNft(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        UserInfo storage _userInfo = userInfo[_pid][_user];
        return _amountWithNft(_userInfo);
    }

    function _amountWithNft(
        UserInfo memory _userInfo
    ) private view returns (uint256) {
        if (_userInfo._tokenIds.length > 0) {
            return
                _userInfo._amount + (_userInfo._amount * nftBonusRate) / 10000;
        } else {
            return _userInfo._amount;
        }
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function totalStakeToken(uint256 _pid) public view returns (uint256) {
        PoolInfo memory _pool = poolInfo[_pid];
        if (_pool._stakeToken == address(token)) {
            return tokenInPool;
        } else {
            return SafeToken.balanceOf(_pool._stakeToken, address(this));
        }
    }

    function apr(
        uint256 _pid,
        uint256 _tokenPrice,
        uint256 _stakeTokenPrice
    ) external view returns (uint256) {
        PoolInfo memory _pool = poolInfo[_pid];
        uint256 _totalStakeToken = totalStakeToken(_pid);
        if (_totalStakeToken == 0) {
            _totalStakeToken =
                10 ** IERC20MetadataUpgradeable(_pool._stakeToken).decimals();
        }
        uint256 _valuePerYear = (_tokenPrice * tokenPerSecond * 31536000) /
            10 ** IERC20MetadataUpgradeable(token).decimals();
        uint256 _totalValueInPool = (_stakeTokenPrice * _totalStakeToken) /
            10 ** IERC20MetadataUpgradeable(_pool._stakeToken).decimals();
        uint256 _totalApr = (_valuePerYear * 10 ** 18) / _totalValueInPool;
        return (_totalApr * _pool._allocPoint) / totalAllocPoint;
    }

    function _harvest(address _to, uint256 _pid) internal {
        PoolInfo storage _pool = poolInfo[_pid];
        UserInfo storage _userInfo = userInfo[_pid][_to];
        require(_userInfo._amount > 0, "Farm::_harvest: nothing to harvest");
        uint256 _totalRewards = (_amountWithNft(_userInfo) *
            _pool._accTokenPerShare) / 1e12;
        uint256 _pending = _totalRewards - _userInfo._rewardDebt;
        if (_pending == 0) {
            return;
        }
        require(
            _pending <= token.balanceOf(address(this)),
            "Farm::_harvest: not enough token"
        );
        uint256 _fee = (_pending * harvestFeeRate) / 10000;
        if (_fee > 0) {
            _safeTokenTransfer(foundation, _fee);
        }
        _safeTokenTransfer(_to, _pending - _fee);

        emit Harvest(_to, _pid, _pending);
    }

    function _safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 _tokenBal = token.balanceOf(address(this));
        if (_amount > _tokenBal) {
            token.transfer(_to, _tokenBal);
        } else {
            token.transfer(_to, _amount);
        }
    }

    function _withdraw(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage _pool = poolInfo[_pid];
        UserInfo storage _userInfo = userInfo[_pid][msg.sender];
        require(
            _userInfo._amount >= _amount,
            "Farm::_withdraw: amount not enough"
        );
        bool _withdrawAll = _amount == _userInfo._amount;
        updatePool(_pid);
        _harvest(msg.sender, _pid);
        _userInfo._amount -= _amount;
        _userInfo._rewardDebt =
            (_amountWithNft(_userInfo) * _pool._accTokenPerShare) /
            1e12;
        if (_pool._stakeToken != address(0)) {
            uint256 _outFee = _pool._outFee;
            if (block.timestamp > _pool._noOutFeeTimestamp) {
                _outFee = 0;
            }
            uint256 _fee = (_amount * _outFee) / 10000;
            if (_fee > 0) {
                SafeToken.safeTransfer(_pool._stakeToken, foundation, _fee);
            }
            SafeToken.safeTransfer(
                _pool._stakeToken,
                address(msg.sender),
                _amount - _fee
            );
            if (_pool._stakeToken == address(token)) {
                tokenInPool -= _amount;
            }
        }

        if (_withdrawAll && _userInfo._tokenIds.length > 0) {
            for (uint256 i = 0; i < _userInfo._tokenIds.length; i++) {
                utopiaNft.safeTransferFrom(
                    address(this),
                    msg.sender,
                    _userInfo._tokenIds[i]
                );
            }
            delete _userInfo._tokenIds;
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage _pool = poolInfo[_pid];
        UserInfo storage _userInfo = userInfo[_pid][msg.sender];
        require(
            _pool._stakeToken != address(0),
            "Pool::deposit:: not accept deposit token"
        );
        updatePool(_pid);
        if (_userInfo._amount > 0) {
            _harvest(msg.sender, _pid);
        }
        SafeToken.safeTransferFrom(
            _pool._stakeToken,
            address(msg.sender),
            address(this),
            _amount
        );
        if (_pool._stakeToken == address(token)) {
            tokenInPool = tokenInPool + _amount;
        }
        _userInfo._amount += _amount;
        _userInfo._rewardDebt =
            (_amountWithNft(_userInfo) * _pool._accTokenPerShare) /
            1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function depositNft(uint256 _pid, uint256 _tokenId) external nonReentrant {
        utopiaNft.safeTransferFrom(msg.sender, address(this), _tokenId);
        UserInfo storage _userInfo = userInfo[_pid][msg.sender];
        require(
            _userInfo._amount > 0,
            "Farm::depositNft: must deposit token first"
        );
        require(
            _userInfo._tokenIds.length < MaxDepositedNum,
            "Farm::depositNft: MaxDepositedNum"
        );
        if (_userInfo._amount > 0) {
            _harvest(msg.sender, _pid);
        }
        _userInfo._tokenIds.push(_tokenId);

        _userInfo._rewardDebt =
            (_amountWithNft(_userInfo) * poolInfo[_pid]._accTokenPerShare) /
            1e12;

        emit DepositNft(msg.sender, _tokenId);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        _withdraw(_pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant {
        updatePool(_pid);
        _harvest(msg.sender, _pid);
        UserInfo storage _userInfo = userInfo[_pid][msg.sender];
        _userInfo._rewardDebt =
            (_amountWithNft(_userInfo) * poolInfo[_pid]._accTokenPerShare) /
            1e12;
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
            poolInfo[_pid]._allocPoint +
            _allocPoint;
        poolInfo[_pid]._allocPoint = _allocPoint;
        poolInfo[_pid]._outFee = _outFee;
        poolInfo[_pid]._noOutFeeTimestamp = _noOutFeeTimestamp;
    }

    function setFoundation(address _foundation) external onlyOwner {
        foundation = _foundation;
    }

    function isDuplicatedPool(address _stakeToken) public view returns (bool) {
        for (uint256 _pid = 0; _pid < poolInfo.length; _pid++) {
            if (poolInfo[_pid]._stakeToken == _stakeToken) {
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
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                _stakeToken: _stakeToken,
                _allocPoint: _allocPoint,
                _lastRewardTimestamp: block.timestamp,
                _accTokenPerShare: 0,
                _outFee: _outFee,
                _noOutFeeTimestamp: _noOutFeeTimestamp
            })
        );
    }

    function setTokenPerSecond(uint256 _tokenPerSecond) external onlyOwner {
        tokenPerSecond = _tokenPerSecond;
    }

    function setNftBonusRate(uint256 _nftBonusRate) external onlyOwner {
        nftBonusRate = _nftBonusRate;
    }

    function massUpdatePools() public {
        for (uint256 pid = 0; pid < poolInfo.length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage _pool = poolInfo[_pid];
        if (block.timestamp <= _pool._lastRewardTimestamp) {
            return;
        }
        uint256 _lpSupply = totalStakeToken(_pid);
        if (_lpSupply == 0) {
            _pool._lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 _tokenReward = ((block.timestamp - _pool._lastRewardTimestamp) *
            tokenPerSecond *
            _pool._allocPoint) / totalAllocPoint;
        _pool._accTokenPerShare += (_tokenReward * 1e12) / _lpSupply;
        _pool._lastRewardTimestamp = block.timestamp;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }
}
