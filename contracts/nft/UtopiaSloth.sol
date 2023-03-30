// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {BaseERC721} from "./BaseERC721.sol";
import {StringsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import {IPriceOracleGetter} from "../interface/IPriceOracleGetter.sol";
import {SafeToken} from "../util/SafeToken.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

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

    using StringsUpgradeable for uint256;
    string baseURI;
    uint256 public constant BATCH_SIZE = 10;
    uint256 public constant MAX_SUPPLY = 1000000;
    address public WETH;
    uint256 public pricePer; // ETH
    IPriceOracleGetter public priceOracle;
    mapping(address => bool) public supportTokensToBuy;
    address payable public foundation;
    uint256 public maxSoldAmount;
    uint256 public soldAmount;

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
        address _wethAddr
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        BaseERC721.initialize(name, symbol, BATCH_SIZE, MAX_SUPPLY);

        baseURI = uri;
        priceOracle = IPriceOracleGetter(_priceOracle);
        pricePer = _pricePer;
        for (uint256 i = 0; i < _supportTokensToBuy.length; i++) {
            supportTokensToBuy[_supportTokensToBuy[i]] = true;
        }
        foundation = payable(_foundation);
        WETH = _wethAddr;
        maxSoldAmount = 5000;
    }

    function changePricePer(uint256 _pricePer) external onlyOwner {
        pricePer = _pricePer;
    }

    function mintByUser(
        uint256 _amount,
        address _tokenToBuy,
        uint256 _walletType,  // 0 metamask, 1 okx wallet
        address _inviter
    ) external payable onlyEOA nonReentrant {
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
        uint256 _needEth = _amount * pricePer; // total ETH
        if (_tokenToBuy == address(0)) {
            // ETH
            require(
                msg.value == _needEth,
                "UtopiaSloth::mintByUser: not enough fund"
            );
            SafeToken.safeTransferETH(foundation, _needEth);
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
            SafeToken.safeTransferFrom(
                _tokenToBuy,
                msg.sender,
                foundation,
                _needToken
            );
        }
        _safeMint(msg.sender, _amount);
        soldAmount = soldAmount + _amount;
        require(soldAmount <= maxSoldAmount, "UtopiaSloth::mintByUser: exceed maxSoldAmount");
        emit Mint(msg.sender, _tokenToBuy, _amount, _walletType, _inviter);
    }

    function mint(uint256 amount) external onlyOwner {
        _safeMint(msg.sender, amount);
    }

    function mintTo(address[] memory addrs) external onlyOwner {
        require(addrs.length <= BATCH_SIZE, "UtopiaSloth::mintTo: addresses too much");
        for (uint256 i = 0; i < addrs.length; i++) {
            _safeMint(addrs[i], 1);
        }
    }

    function setBaseURI(string memory _baseURI_) external onlyOwner {
        baseURI = _baseURI_;
    }

    function tokenURI(
        uint256 tokenId
    ) public view virtual override returns (string memory) {
        if (_exists(tokenId)) {
            return
                string(abi.encodePacked(baseURI, tokenId.toString(), ".json"));
        }

        return "unknown.json";
    }
}
