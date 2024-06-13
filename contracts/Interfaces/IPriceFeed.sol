// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IPriceFeed {
  struct Dependencies {
    address attributes;
  }
  // --- Function ---
  function fetchPrice(address _asset) external returns (uint256);
  function setInitialPrice(address _asset) external;
  function setTimeout(uint256 _timeout) external;
  function setMaxPriceDeviation(uint256 _maxPriceDeviation) external;

  event LastGoodPriceUpdated(address _asset, uint256 _lastGoodPrice);
  event TimeoutUpdated(uint256 _timeout);
  event MaxPriceDeviationUpdated(uint256 _maxPriceDeviation);
  event ChainlinkIsBroken(address _asset, address _priceAggregator, uint80 _roundId);
  event DIAIsBroken(address _asset, address _priceAggregator);
  event ChainlinkIsFrozen(address _asset, address _priceAggregator, uint80 _roundId);
  event DIAIsFrozen(address _asset, address _priceAggregator);
  event ChainlinkPriceChangeAboveMax(address _asset, address _priceAggregator, uint80 _roundId);
}
