// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MainDemoConsumerBase} from "@redstone-finance/evm-connector/contracts/data-services/MainDemoConsumerBase.sol";
import {IPriceOracleGetter} from "../../interface/IPriceOracleGetter.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

struct Asset {
    bytes32 _name;
    address _addr;
}

contract ZkPriceOracle is
    IPriceOracleGetter,
    OwnableUpgradeable,
    MainDemoConsumerBase
{
    event BaseCurrencySet(
        address indexed _baseCurrency,
        uint256 _baseCurrencyUnit
    );

    address public BASE_CURRENCY;
    uint256 public BASE_CURRENCY_UNIT;
    mapping(address => Asset) public assets;

    address public feeder;
    mapping(address => uint256) public feedPrices;

    function initialize(
        Asset[] memory _assets,
        address _baseCurrency,
        uint256 _baseCurrencyUnit,
        address _feeder
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();

        for (uint256 i = 0; i < _assets.length; i++) {
            assets[_assets[i]._addr] = _assets[i];
        }
        BASE_CURRENCY = _baseCurrency;
        BASE_CURRENCY_UNIT = _baseCurrencyUnit;
        emit BaseCurrencySet(_baseCurrency, _baseCurrencyUnit);

        feeder = _feeder;
    }

    modifier onlyFeeder() {
        require(msg.sender == feeder, "ZkPriceOracle::onlyFeeder: not feeder");
        _;
    }

    function changeFeeder(address _feeder) external onlyOwner {
        feeder = _feeder;
    }

    function feedAndCall(
        address[] calldata _assetAddrs,
        uint256[] calldata _assetPrices,
        address _callAddr,
        bytes calldata _data
    ) external onlyFeeder {
        require(
            _assetAddrs.length > 0,
            "ZkPriceOracle::feedAndCall: length is wrong"
        );
        require(
            _assetAddrs.length == _assetPrices.length,
            "ZkPriceOracle::feedAndCall: length is not equal"
        );
        for (uint256 i = 0; i < _assetAddrs.length; i++) {
            feedPrices[_assetAddrs[i]] = _assetPrices[i];
        }
        if (_data.length > 0) {
            AddressUpgradeable.functionCall(_callAddr, _data);
        }
    }

    function getAssetPriceFromRedstone(
        bytes32 _asset
    ) external view returns (uint256 _price) {
        return getOracleNumericValueFromTxMsg(_asset);
    }

    function getAssetPrice(
        address _assetAddr
    ) public view override returns (uint256) {
        uint256 _result;
        if (_assetAddr == BASE_CURRENCY) {
            _result = BASE_CURRENCY_UNIT;
        } else {
            // 1
            try
                this.getAssetPriceFromRedstone(assets[_assetAddr]._name)
            returns (uint256 _price) {
                if (_price > 0) {
                    if (_result == 0) {
                        _result = _price;
                    } else {
                        if (
                            _price > (_result * 995) / 1000 &&
                            _price < (_result * 1005) / 1000
                        ) {
                            _result = (_result + _price) / 2;
                        }
                    }
                }
            } catch {}
            // 2
            if (feedPrices[_assetAddr] > 0) {
                if (_result == 0) {
                    _result = feedPrices[_assetAddr];
                } else {
                    if (
                        feedPrices[_assetAddr] > (_result * 995) / 1000 &&
                        feedPrices[_assetAddr] < (_result * 1005) / 1000
                    ) {
                        _result = (_result + feedPrices[_assetAddr]) / 2;
                    }
                }
            }
        }
        require(_result > 0, "ZkPriceOracle::getAssetPrice: price error");
        return _result;
    }

    function getAssetsPrices(
        address[] calldata _assetAddrs
    ) external view returns (uint256[] memory) {
        uint256[] memory _prices = new uint256[](_assetAddrs.length);
        for (uint256 i = 0; i < _assetAddrs.length; i++) {
            _prices[i] = getAssetPrice(_assetAddrs[i]);
        }
        return _prices;
    }
}
