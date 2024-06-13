// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {AggregatorV3Interface} from "./Interfaces/AggregatorV3Interface.sol";
import "./Dependencies/CheckContract.sol";

contract AggregatorV3Wrapper is CheckContract, AggregatorV3Interface {

    IERC20Upgradeable public immutable vaultToken;
    AggregatorV3Interface public immutable assetAggregatorV3;
    address public immutable totalAssetsAddress;
    bytes4 public immutable TOTAL_ASSETS_SELECTOR;

    constructor(
        address _vaultToken,
        address _assetAggregatorV3,
        address _totalAssetsAddress,
        string memory _totalAssetsMethodSignature
    ) {
        checkContract(_vaultToken);
        checkContract(_assetAggregatorV3);
        checkContract(_totalAssetsAddress);

        vaultToken = IERC20Upgradeable(_vaultToken);
        assetAggregatorV3 = AggregatorV3Interface(_assetAggregatorV3);
        totalAssetsAddress = _totalAssetsAddress;
        TOTAL_ASSETS_SELECTOR = bytes4(keccak256(bytes(_totalAssetsMethodSignature)));
    }

    function decimals() external view returns (uint8) {
        return assetAggregatorV3.decimals();
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        (uint256 totalDeposits, uint256 totalSupply) = _getVaultTokenData();
        (roundId, answer, startedAt, updatedAt, answeredInRound) = assetAggregatorV3.latestRoundData();
        answer = _getPrice(answer, totalDeposits, totalSupply);
    }

    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        (uint256 totalDeposits, uint256 totalSupply) = _getVaultTokenData();
        (roundId, answer, startedAt, updatedAt, answeredInRound) = assetAggregatorV3.getRoundData(_roundId);
        answer = _getPrice(answer, totalDeposits, totalSupply);
    }

    function _getVaultTokenData() internal view returns (uint256 totalDeposits, uint256 totalSupply) {
        (bool success, bytes memory data) = totalAssetsAddress.staticcall(abi.encodeWithSelector(TOTAL_ASSETS_SELECTOR));
        require(success, "Failed to get total deposits");
        totalDeposits = abi.decode(data, (uint256));
        totalSupply = vaultToken.totalSupply();

        return (totalDeposits, totalSupply);
    }

    function _getPrice(
        int256 _assetPrice,
        uint256 _totalDeposits,
        uint256 _totalSupply
    ) internal pure returns (int256) {
        require(_totalSupply != 0, "Total supply cannot be zero");
        return _assetPrice * int256(_totalDeposits) / int256(_totalSupply);
    }
}
