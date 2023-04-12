// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IGmxPriceFeeder} from "../../interface/IGmxPriceFeeder.sol";
import {IPriceOracleGetter} from "../../interface/IPriceOracleGetter.sol";
import {IChainlinkAggregator} from "../../interface/IChainlinkAggregator.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

contract ArbPriceOracle is IPriceOracleGetter, OwnableUpgradeable {
    event BaseCurrencySet(
        address indexed baseCurrency,
        uint256 baseCurrencyUnit
    );
    event AssetSourceUpdated(address indexed asset, address indexed source);
    event FallbackOracleUpdated(address indexed fallbackOracle);

    mapping(address => IChainlinkAggregator) private assetsSources;
    address public BASE_CURRENCY;
    uint256 public BASE_CURRENCY_UNIT;

    address public feeder;
    mapping(address => uint256) public feedPrices;

    IGmxPriceFeeder public gmxPriceFeeder;

    function initialize(
        address[] memory _assets,
        address[] memory _sources,
        address _baseCurrency,
        uint256 _baseCurrencyUnit,
        address _feeder,
        address _gmxPriceFeeder
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();

        _setAssetsSources(_assets, _sources);
        BASE_CURRENCY = _baseCurrency;
        BASE_CURRENCY_UNIT = _baseCurrencyUnit;
        emit BaseCurrencySet(_baseCurrency, _baseCurrencyUnit);

        feeder = _feeder;
        gmxPriceFeeder = IGmxPriceFeeder(_gmxPriceFeeder);
    }

    modifier onlyFeeder() {
        require(msg.sender == feeder, "ArbPriceOracle::onlyFeeder: not feeder");
        _;
    }

    function changeFeeder(address _feeder) external onlyOwner {
        feeder = _feeder;
    }

    function changeGmxPriceFeeder(address _gmxPriceFeeder) external onlyOwner {
        gmxPriceFeeder = IGmxPriceFeeder(_gmxPriceFeeder);
    }

    function feedAndCall(
        address[] calldata _assetAddrs,
        uint256[] calldata _assetPrices,
        address _callAddr,
        bytes calldata _data
    ) external onlyFeeder {
        require(
            _assetAddrs.length > 0,
            "ArbPriceOracle::feedAndCall: length is wrong"
        );
        require(
            _assetAddrs.length == _assetPrices.length,
            "ArbPriceOracle::feedAndCall: length is not equal"
        );
        for (uint256 i = 0; i < _assetAddrs.length; i++) {
            feedPrices[_assetAddrs[i]] = _assetPrices[i];
        }
        if (_data.length > 0) {
            AddressUpgradeable.functionCall(_callAddr, _data);
        }
    }

    function setAssetSources(
        address[] calldata _assets,
        address[] calldata _sources
    ) external onlyOwner {
        _setAssetsSources(_assets, _sources);
    }

    function _setAssetsSources(
        address[] memory _assets,
        address[] memory _sources
    ) internal {
        require(
            _assets.length == _sources.length,
            "ArbPriceOracle::_setAssetsSources: INCONSISTENT_PARAMS_LENGTH"
        );
        for (uint256 i = 0; i < _assets.length; i++) {
            assetsSources[_assets[i]] = IChainlinkAggregator(_sources[i]);
            emit AssetSourceUpdated(_assets[i], _sources[i]);
        }
    }

    function getPrices(
        address _assetAddr
    ) public view returns (uint256[] memory) {
        uint256[] memory _prices = new uint256[](3);
        // 1
        if (address(assetsSources[_assetAddr]) != address(0)) {
            try IChainlinkAggregator(assetsSources[_assetAddr]).latestAnswer() returns (
                int256 _priceTmp
            ) {
                _prices[0] = uint256(_priceTmp);
            } catch {}
        }

        // 2
        _prices[1] = feedPrices[_assetAddr];

        // 3
        if (address(gmxPriceFeeder) != address(0)) {
            try gmxPriceFeeder.getPrice(_assetAddr, true, true, false) returns (
                uint256 _price
            ) {
                _prices[2] = _price / 10 ** 22;
            } catch {}
        }

        return _prices;
    }

    function getAssetPrice(
        address _assetAddr
    ) public view override returns (uint256) {
        uint256 _result;
        if (_assetAddr == BASE_CURRENCY) {
            _result = BASE_CURRENCY_UNIT;
        } else {
            uint256[] memory _prices = getPrices(_assetAddr);
            for (uint256 i = 0; i < _prices.length; i++) {
                if (_prices[i] > 0) {
                    if (_result == 0) {
                        _result = _prices[i];
                    } else {
                        _result = (_result + _prices[i]) / 2;
                    }
                }
            }
        }
        require(_result > 0, "ArbPriceOracle::getAssetPrice: price error");
        return _result;
    }

    function getAssetsPrices(
        address[] calldata _assets
    ) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            prices[i] = getAssetPrice(_assets[i]);
        }
        return prices;
    }

    function getSourceOfAsset(address _asset) external view returns (address) {
        return address(assetsSources[_asset]);
    }
}
