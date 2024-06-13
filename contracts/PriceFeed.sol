// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/IDIA.sol";
import "./Interfaces/AggregatorV3Interface.sol";
import "./Interfaces/IAttributes.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";
import { StablisMath } from "./Dependencies/StablisMath.sol";

contract PriceFeed is OwnableUpgradeable, CheckContract, BaseMath, IPriceFeed {
    string constant public NAME = "PriceFeed";

    IAttributes public attributes;

    uint256 constant public TARGET_DIGITS = 18;

    // Maximum time period allowed since Chainlink's latest round data timestamp, beyond which Chainlink is considered frozen.
    uint256 public timeout;

    // Maximum deviation allowed between two consecutive Chainlink oracle prices. 18-digit precision.
    uint256 public maxPriceDeviationFromPreviousRound;

    mapping(address => uint256) public lastGoodPrice;

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    struct DIAResponse {
        uint128 price;
        uint128 timestamp;
    }

    // --- Dependency setters ---

    function initialize(Dependencies calldata _dependencies, address _multiSig) external initializer {
        checkContract(_dependencies.attributes);

        __Ownable_init();

        attributes = IAttributes(_dependencies.attributes);

        timeout = 14_400;  // 4 hours: 60 * 60 * 4
        maxPriceDeviationFromPreviousRound = 5e17; // 50%

        _transferOwnership(_multiSig);
    }

    // --- Functions ---

    /*
    * setInitialPrice():
    * Sets the initial price for an asset to serve as first reference for LastGoodPrice.
    * Called by Attributes when a new asset is added.
    */
    function setInitialPrice(address _asset) external {
        _requireCallerIsAttributes();
        (bool isDIA, ) = attributes.getDIA(_asset);

        if (isDIA) {
            _setInitialPriceDIA(_asset);
        } else {
            _setInitialPriceChainlink(_asset);
        }
    }

    function _setInitialPriceChainlink(address _asset) internal {
        // Chainlink validity checks
        (ChainlinkResponse memory chainlinkResponse, ChainlinkResponse memory prevChainlinkResponse,) = _getChainlinkData(_asset);

        require(!_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse) && !_chainlinkIsFrozen(chainlinkResponse),
            "PriceFeed: Chainlink must be working and current");

        _storePrice(_asset, uint256(chainlinkResponse.answer), uint256(chainlinkResponse.decimals));
    }

    function _setInitialPriceDIA(address _asset) internal {
        (DIAResponse memory diaResponse,) = _getDIAData(_asset);

        require(!_diaIsBroken(diaResponse) && !_diaIsFrozen(diaResponse),
            "PriceFeed: DIA must be working and current");

        _storePrice(_asset, uint256(diaResponse.price), 8);
    }

    /*
    * fetchPrice():
    * Returns the latest price obtained from the Oracle. Called by functions that require a current price.
    *
    * Also callable by anyone externally.
    *
    */
    function fetchPrice(address _asset) external override returns (uint256) {
        (bool isDIA,) = attributes.getDIA(_asset);

        if (isDIA) {
            return _fetchPriceDIA(_asset);
        }
        return _fetchPriceChainlink(_asset);
    }

    function _fetchPriceChainlink(address _asset) internal returns (uint256) {
        (ChainlinkResponse memory chainlinkResponse, ChainlinkResponse memory prevChainlinkResponse,
            address priceAggregator) = _getChainlinkData(_asset);

        if (_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse)) {
            emit ChainlinkIsBroken(_asset, priceAggregator, chainlinkResponse.roundId);
            return lastGoodPrice[_asset];
        }

        if (_chainlinkIsFrozen(chainlinkResponse)) {
            emit ChainlinkIsFrozen(_asset, priceAggregator, chainlinkResponse.roundId);
            return lastGoodPrice[_asset];
        }

        if (_chainlinkPriceChangeAboveMax(chainlinkResponse, prevChainlinkResponse)) {
            emit ChainlinkPriceChangeAboveMax(_asset, priceAggregator, chainlinkResponse.roundId);
            return lastGoodPrice[_asset];
        }

        return _storePrice(_asset, uint256(chainlinkResponse.answer), uint256(chainlinkResponse.decimals));
    }

    function _fetchPriceDIA(address _asset) internal returns (uint256) {
        (DIAResponse memory diaResponse, address priceAggregator) = _getDIAData(_asset);

        if (_diaIsBroken(diaResponse)) {
            emit DIAIsBroken(_asset, priceAggregator);
            return lastGoodPrice[_asset];
        }

        if (_diaIsFrozen(diaResponse)) {
            emit DIAIsFrozen(_asset, priceAggregator);
            return lastGoodPrice[_asset];
        }

        return _storePrice(_asset, uint256(diaResponse.price), uint256(8));
    }

    function _getChainlinkData(address _asset) internal view returns (
        ChainlinkResponse memory,
        ChainlinkResponse memory,
        address
    ) {
        AggregatorV3Interface priceAggregator = AggregatorV3Interface(attributes.getPriceAggregator(_asset));
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse(priceAggregator);
        ChainlinkResponse memory prevChainlinkResponse = _getPrevChainlinkResponse(priceAggregator, chainlinkResponse.roundId, chainlinkResponse.decimals);

        return (chainlinkResponse, prevChainlinkResponse, address(priceAggregator));
    }

    function _getDIAData(address _asset) internal view returns (DIAResponse memory diaResponse, address) {
        (,string memory diaKey) = attributes.getDIA(_asset);

        IDIA oracle = IDIA(attributes.getPriceAggregator(_asset));
        (diaResponse.price, diaResponse.timestamp) = oracle.getValue(diaKey);

        return (diaResponse, address(oracle));
    }

    function _getCurrentChainlinkResponse(AggregatorV3Interface priceAggregator) internal view returns (ChainlinkResponse memory chainlinkResponse) {
        // First, try to get current decimal precision:
        try priceAggregator.decimals() returns (uint8 decimals) {
            // If call to Chainlink succeeds, record the current decimal precision
            chainlinkResponse.decimals = decimals;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }

        // Secondly, try to get latest price data:
        try priceAggregator.latestRoundData() returns
        (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        )
        {
            // If call to Chainlink succeeds, return the response and success = true
            chainlinkResponse.roundId = roundId;
            chainlinkResponse.answer = answer;
            chainlinkResponse.timestamp = timestamp;
            chainlinkResponse.success = true;
            return chainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }
    }

    function _getPrevChainlinkResponse(AggregatorV3Interface priceAggregator, uint80 _currentRoundId, uint8 _currentDecimals) internal view returns (ChainlinkResponse memory prevChainlinkResponse) {
        /*
        * NOTE: Chainlink only offers a current decimals() value - there is no way to obtain the decimal precision used in a
        * previous round.  We assume the decimals used in the previous round are the same as the current round.
        */

        // Try to get the price data from the previous round:
        try priceAggregator.getRoundData(_currentRoundId - 1) returns
        (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        )
        {
            // If call to Chainlink succeeds, return the response and success = true
            prevChainlinkResponse.roundId = roundId;
            prevChainlinkResponse.answer = answer;
            prevChainlinkResponse.timestamp = timestamp;
            prevChainlinkResponse.decimals = _currentDecimals;
            prevChainlinkResponse.success = true;
            return prevChainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return prevChainlinkResponse;
        }
    }

    /* Chainlink is considered broken if its current or previous round data is in any way bad. We check the previous round
    * because it is necessary data for the price deviation check.
    */
    function _chainlinkIsBroken(ChainlinkResponse memory _currentResponse, ChainlinkResponse memory _prevResponse) internal view returns (bool) {
        return _badChainlinkResponse(_currentResponse) || _badChainlinkResponse(_prevResponse);
    }

    function _diaIsBroken(DIAResponse memory _response) internal view returns (bool) {
        return _response.price == 0 || _response.timestamp == 0 || _response.timestamp > block.timestamp;
    }

    function _badChainlinkResponse(ChainlinkResponse memory _response) internal view returns (bool) {
        // Check for response call reverted
        if (!_response.success) { return true; }
        // Check for an invalid roundId that is 0
        if (_response.roundId == 0) { return true; }
        // Check for an invalid timeStamp that is 0, or in the future
        if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {return true;}
        // Check for non-positive price
        if (_response.answer <= 0) { return true; }

        return false;
    }

    function _chainlinkIsFrozen(ChainlinkResponse memory _response) internal view returns (bool) {
        return block.timestamp - _response.timestamp > timeout;
    }

    function _diaIsFrozen(DIAResponse memory _response) internal view returns (bool) {
        return block.timestamp - _response.timestamp > timeout;
    }

    function _chainlinkPriceChangeAboveMax(ChainlinkResponse memory _currentResponse, ChainlinkResponse memory _prevResponse) internal view returns (bool) {
        uint256 currentScaledPrice = _scalePriceByDigits(uint256(_currentResponse.answer), _currentResponse.decimals);
        uint256 prevScaledPrice = _scalePriceByDigits(uint256(_prevResponse.answer), _prevResponse.decimals);

        uint256 minPrice = StablisMath._min(currentScaledPrice, prevScaledPrice);
        uint256 maxPrice = StablisMath._max(currentScaledPrice, prevScaledPrice);

        /*
        * Use the larger price as the denominator:
        * - If price decreased, the percentage deviation is in relation to the the previous price.
        * - If price increased, the percentage deviation is in relation to the current price.
        */
        uint256 percentDeviation = ((maxPrice - minPrice) * DECIMAL_PRECISION) / maxPrice;

        // Return true if price has more than doubled, or more than halved.
        return percentDeviation > maxPriceDeviationFromPreviousRound;
    }

    function _scalePriceByDigits(uint256 _price, uint256 _decimals) internal pure returns (uint) {
        /*
        * Convert the price returned by the Chainlink oracle to an 18-digit decimal for use by Stablis.
        * At date of Stablis launch, Chainlink uses an 8-digit price, but we also handle the possibility of
        * future changes.
        *
        */
        uint256 price;
        if (_decimals >= TARGET_DIGITS) {
            // Scale the returned price value down to Stablis target precision
            price = _price / (10 ** (_decimals - TARGET_DIGITS));
        }
        else if (_decimals < TARGET_DIGITS) {
            // Scale the returned price value up to Stablis target precision
            price = _price * (10 ** (TARGET_DIGITS - _decimals));
        }
        return price;
    }

    function _storePrice(address _asset, uint256 _price, uint256 _decimals) internal returns (uint256) {
        uint256 scaledPrice = _scalePriceByDigits(_price, _decimals);
        _storePrice(_asset, scaledPrice);

        return scaledPrice;
    }

    function _storePrice(address _asset, uint256 _currentPrice) internal {
        lastGoodPrice[_asset] = attributes.isERC4626(_asset) ? _getERC4626Price(_asset, _currentPrice) : _currentPrice;
        emit LastGoodPriceUpdated(_asset, _currentPrice);
    }

    function _getERC4626Price(address _asset, uint256 _currentPrice) internal view returns (uint256) {
        IERC4626 erc4626Asset = IERC4626(_asset);
        return _currentPrice * erc4626Asset.totalAssets() / erc4626Asset.totalSupply();
    }

    function setTimeout(uint256 _timeout) external onlyOwner {
        timeout = _timeout;
        emit TimeoutUpdated(_timeout);
    }

    function setMaxPriceDeviation(uint256 _maxPriceDeviation) external onlyOwner {
        maxPriceDeviationFromPreviousRound = _maxPriceDeviation;
        emit MaxPriceDeviationUpdated(_maxPriceDeviation);
    }

    function _requireCallerIsAttributes() internal view {
        require(msg.sender == address(attributes), "PriceFeed: Caller is not Attributes");
    }
}
