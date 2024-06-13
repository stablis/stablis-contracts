// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IOracle {
  function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
  function getRoundData(uint80 _roundId) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
  function decimals() external view returns (uint8);
  function setDecimals(uint8 decimals) external;
  function setNewRound(int256 newAnswer) external;
}
