// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPriceOracle} from "../../interface/IPriceOracle.sol";
import {IVaultGateway} from "../../interface/IVaultGateway.sol";
import {ISyncSwapPool} from "../../interface/ISyncSwapPool.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";


struct Asset {
    string _name;
    address _addr;
}

interface IDIAOracleV2 {
    function getValue(string memory) external view returns (uint128, uint128);
}

contract ZkPriceOracle is IPriceOracle, OwnableUpgradeable {
    event BaseCurrencySet(
        address indexed _baseCurrency,
        uint256 _baseCurrencyUnit
    );

    address public BASE_CURRENCY;
    uint256 public BASE_CURRENCY_UNIT;
    mapping(address => Asset) public assets;

    address public feeder;
    mapping(address => uint256) public feedPrices;

    address public diaOracle;

    address public ups;
    address public vaultGateway;
    address public uptUpsLp;
    address public upt;

    function initialize(
        Asset[] memory _assets,
        address _baseCurrency,
        uint256 _baseCurrencyUnit,
        address _feeder,
        address _diaOracle
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();

        for (uint256 i = 0; i < _assets.length; i++) {
            assets[_assets[i]._addr] = _assets[i];
        }
        BASE_CURRENCY = _baseCurrency;
        BASE_CURRENCY_UNIT = _baseCurrencyUnit;
        emit BaseCurrencySet(_baseCurrency, _baseCurrencyUnit);

        feeder = _feeder;
        diaOracle = _diaOracle;
    }

    function changeAddresses(address _ups, address _vaultGateway, address _uptUpsLp, address _upt) external onlyOwner {
        ups = _ups;
        vaultGateway = _vaultGateway;
        uptUpsLp = _uptUpsLp;
        upt = _upt;
    }

    modifier onlyFeederOrOwner() {
        require(msg.sender == feeder || msg.sender == owner(), "ZkPriceOracle::onlyFeederOrOwner: not feeder or owner");
        _;
    }

    function changeFeeder(address _feeder) external onlyOwner {
        feeder = _feeder;
    }

    function changeDiaOracle(address _diaOracle) external onlyOwner {
        diaOracle = _diaOracle;
    }

    function feedAndCall(
        address[] calldata _assetAddrs,
        uint256[] calldata _assetPrices,
        address _callAddr,
        bytes calldata _data
    ) external onlyFeederOrOwner {
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

    function stringToBytes32(
        string memory source
    ) public pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }

    function getPrices(
        address _assetAddr
    ) public view returns (uint256[] memory) {
        uint256[] memory _prices = new uint256[](2);
        // 1
        if (_assetAddr == ups) {
            _prices[0] = IVaultGateway(vaultGateway).utopiaTokenPrice();
            return _prices;
        }

        if (_assetAddr == upt) {
            uint256 _upsAmount = ISyncSwapPool(uptUpsLp).getAmountOut(upt, 10 ** IERC20MetadataUpgradeable(upt).decimals(), address(0));
            _prices[0] = _upsAmount * getPrices(ups)[0] / (10 ** IERC20MetadataUpgradeable(ups).decimals());
            return _prices;
        }

        if (_assetAddr == uptUpsLp) {
            (, uint _upsAmount) = ISyncSwapPool(uptUpsLp).getReserves();
            uint256 _lpSupply = ISyncSwapPool(uptUpsLp).totalSupply();
            _prices[0] = _upsAmount * getPrices(ups)[0] * 2 * (10 ** IERC20MetadataUpgradeable(uptUpsLp).decimals()) / _lpSupply / (10 ** IERC20MetadataUpgradeable(ups).decimals());
            return _prices;
        }
        _prices[0] = feedPrices[_assetAddr];

        // 2
        if (diaOracle != address(0)) {
            try
                IDIAOracleV2(diaOracle).getValue(
                    string.concat(assets[_assetAddr]._name, "/USD")
                )
            returns (uint128 _latestPrice, uint128) {
                _prices[1] = _latestPrice;
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
                        if (
                            _prices[i] > _result / 2 && _prices[i] < _result * 2
                        ) {
                            _result = (_result + _prices[i]) / 2;
                        }
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
