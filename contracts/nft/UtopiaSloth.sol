// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {BaseERC721} from "./BaseERC721.sol";
import {StringsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import {IPriceOracle} from "../interface/IPriceOracle.sol";
import {IUpsaToken} from "../interface/IUpsaToken.sol";
import {SafeToken} from "../util/SafeToken.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IInviteManager} from "../interface/IInviteManager.sol";

struct InviteInfo {
    address _addr;
    uint256 _amount;
}

struct InviteRecord {
    address _addr;
    uint256 _amount;
    address _token;
    uint256 _tokenAmount;
    uint256 _rebates;
    uint256 _timestamp;
}

contract UtopiaSloth is
    OwnableUpgradeable,
    BaseERC721,
    ReentrancyGuardUpgradeable
{
    event Mint(
        address indexed _user,
        address indexed _tokenToBuy,
        uint256 _amount,
        uint256 _walletType,
        address _inviter
    );

    event RebateRecordEvent(
        address indexed _inviter,
        address _invitee,
        uint256 _amount,
        address _token,
        uint256 _tokenAmount,
        uint256 _rebates,
        uint256 _time
    );

    using StringsUpgradeable for uint256;
    string baseURI;
    uint256 public constant BATCH_SIZE = 10;
    uint256 public constant MAX_SUPPLY = 1000000;
    address public WETH;
    uint256 public pricePer; // ETH
    IPriceOracle public priceOracle;
    mapping(address => bool) public supportTokensToBuy;
    address payable public foundation;
    uint256 public maxSoldAmount;
    uint256 public soldAmount;
    bool public isPausedSell;
    bool public isPausedTransfer;
    IUpsaToken public upta;
    uint256 public inviteRate; // out of date
    mapping(address => InviteInfo[]) public inviteRecords; // out of date
    IInviteManager public inviteManager;
    mapping(address => InviteRecord[]) public inviteRecords1; // out of date

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "UtopiaSloth::onlyEOA: not eoa");
        _;
    }

    function initialize(
        string memory name,
        string memory symbol,
        string memory uri,
        uint256 _pricePer,
        address _priceOracle,
        address[] memory _supportTokensToBuy,
        address _foundation,
        address _wethAddr,
        uint256 _maxSoldAmount,
        address _upta,
        address _inviteManager
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        BaseERC721.initialize(name, symbol, BATCH_SIZE, MAX_SUPPLY);

        baseURI = uri;
        priceOracle = IPriceOracle(_priceOracle);
        pricePer = _pricePer;
        for (uint256 i = 0; i < _supportTokensToBuy.length; i++) {
            supportTokensToBuy[_supportTokensToBuy[i]] = true;
        }
        foundation = payable(_foundation);
        WETH = _wethAddr;
        maxSoldAmount = _maxSoldAmount;
        upta = IUpsaToken(_upta);
        inviteManager = IInviteManager(_inviteManager);
    }

    function setSupportTokensToBuy(
        address[] memory _supportTokensToBuy
    ) external onlyOwner {
        for (uint256 i = 0; i < _supportTokensToBuy.length; i++) {
            supportTokensToBuy[_supportTokensToBuy[i]] = true;
        }
    }

    function changeInviteManager(address _inviteManager) external onlyOwner {
        inviteManager = IInviteManager(_inviteManager);
    }

    function changeUpta(address _upta) external onlyOwner {
        upta = IUpsaToken(_upta);
    }

    function changePricePer(uint256 _pricePer) external onlyOwner {
        pricePer = _pricePer;
    }

    function changeMaxSoldAmount(uint256 _maxSoldAmount) external onlyOwner {
        maxSoldAmount = _maxSoldAmount;
    }

    function pauseSell() external onlyOwner {
        isPausedSell = true;
    }

    function startSell() external onlyOwner {
        isPausedSell = false;
    }

    function pauseTransfer() external onlyOwner {
        isPausedTransfer = true;
    }

    function startTransfer() external onlyOwner {
        isPausedTransfer = false;
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        require(!isPausedTransfer, "UtopiaSloth::transferFrom: paused");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override {
        require(!isPausedTransfer, "UtopiaSloth::safeTransferFrom: paused");
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public virtual override {
        require(!isPausedTransfer, "UtopiaSloth::safeTransferFrom: paused");
        _transfer(from, to, tokenId);
        require(
            _checkOnERC721Received(from, to, tokenId, _data),
            "BaseERC721: transfer to non ERC721Receiver implementer"
        );
    }

    function mintByUser(
        uint256 _amount,
        address _tokenToBuy,
        uint256 _walletType,
        address _inviter
    ) external payable onlyEOA nonReentrant {
        require(!isPausedSell, "UtopiaSloth::mintByUser: paused");
        require(
            pricePer > 0,
            "UtopiaSloth::mintByUser: price must larger than 0"
        );
        require(
            _tokenToBuy == address(0) || supportTokensToBuy[_tokenToBuy],
            "UtopiaSloth::mintByUser: not support token to buy"
        );
        require(
            _amount <= BATCH_SIZE,
            "UtopiaSloth::mintByUser: too large _amount"
        );
        require(
            balanceOf(msg.sender) + _amount <= 10,
            "UtopiaSloth::mintByUser: too large _amount"
        );
        if (address(inviteManager) != address(0) && _inviter != address(0)) {
            inviteManager.tryInvite(_inviter, msg.sender);
        }

        uint256 _needEth = _amount * pricePer; // total ETH
        if (_tokenToBuy == address(0)) {
            // ETH
            require(
                msg.value == _needEth,
                "UtopiaSloth::mintByUser: not enough fund"
            );
            if (
                address(inviteManager) != address(0) &&
                inviteManager.inviters(msg.sender) != address(0)
            ) {
                uint256 _inviteReward = (_needEth *
                    inviteManager.inviteRateOfNftSell()) / 10000;
                SafeToken.safeTransferETH(
                    inviteManager.inviters(msg.sender),
                    _inviteReward
                );
                SafeToken.safeTransferETH(foundation, _needEth - _inviteReward);
                emit RebateRecordEvent(
                    inviteManager.inviters(msg.sender),
                    msg.sender,
                    _amount,
                    _tokenToBuy,
                    _needEth,
                    _inviteReward,
                    block.timestamp
                );
            } else {
                SafeToken.safeTransferETH(foundation, _needEth);
            }
        } else {
            // ERC20
            uint256 _ethPrice = priceOracle.getAssetPrice(WETH);
            require(_ethPrice > 0, "UtopiaSloth::mintByUser: bad eth price");
            uint256 _tokenPrice = priceOracle.getAssetPrice(_tokenToBuy);
            require(
                _tokenPrice > 0,
                "UtopiaSloth::mintByUser: bad token price"
            );
            uint256 _needToken = (_needEth *
                _ethPrice *
                (10 ** IERC20MetadataUpgradeable(_tokenToBuy).decimals())) /
                _tokenPrice /
                (10 ** 18);
            if (
                address(inviteManager) != address(0) &&
                inviteManager.inviters(msg.sender) != address(0)
            ) {
                uint256 _inviteReward = (_needToken *
                    inviteManager.inviteRateOfNftSell()) / 10000;
                SafeToken.safeTransferFrom(
                    _tokenToBuy,
                    msg.sender,
                    inviteManager.inviters(msg.sender),
                    _inviteReward
                );
                SafeToken.safeTransferFrom(
                    _tokenToBuy,
                    msg.sender,
                    foundation,
                    _needToken - _inviteReward
                );
                emit RebateRecordEvent(
                    inviteManager.inviters(msg.sender),
                    msg.sender,
                    _amount,
                    _tokenToBuy,
                    _needToken,
                    _inviteReward,
                    block.timestamp
                );
            } else {
                SafeToken.safeTransferFrom(
                    _tokenToBuy,
                    msg.sender,
                    foundation,
                    _needToken
                );
            }
        }
        _safeMint(msg.sender, _amount);
        soldAmount = soldAmount + _amount;
        require(
            soldAmount <= maxSoldAmount,
            "UtopiaSloth::mintByUser: exceed maxSoldAmount"
        );
        if (address(upta) != address(0)) {
            upta.mint(msg.sender, 400 * (10 ** upta.decimals()));
        }
        emit Mint(msg.sender, _tokenToBuy, _amount, _walletType, _inviter);
    }

    function mint(uint256 amount) external onlyOwner {
        soldAmount = soldAmount + amount;
        _safeMint(msg.sender, amount);
    }

    function changeSoldAmount(uint256 _soldAmount) external onlyOwner {
        soldAmount = _soldAmount;
    }

    function mintTo(address[] memory addrs) external onlyOwner {
        require(
            addrs.length <= BATCH_SIZE,
            "UtopiaSloth::mintTo: addresses too much"
        );
        soldAmount = soldAmount + addrs.length;
        for (uint256 i = 0; i < addrs.length; i++) {
            _safeMint(addrs[i], 1);
        }
    }

    function setBaseURI(string memory _baseURI_) external onlyOwner {
        baseURI = _baseURI_;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        if (_exists(tokenId)) {
            return
                string(abi.encodePacked(baseURI, tokenId.toString(), ".json"));
        }

        return "unknown.json";
    }
}
