// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
pragma experimental ABIEncoderV2;

import "./ChestManager.sol";
import "./SortedChests.sol";

import "./Dependencies/CheckContract.sol";

/*  Helper contract for grabbing Chest data for the front end. Not part of the core Stablis system. */
contract MultiChestGetter is CheckContract {
    struct CombinedChestData {
        address owner;

        uint256 debt;
        uint256 coll;
        uint256 stake;

        uint256 snapshotETH;
        uint256 snapshotUSDSDebt;
    }

    struct Dependencies {
        address chestManager;
        address sortedChests;
    }

    ChestManager public chestManager; // XXX Chests missing from IChestManager?
    ISortedChests public sortedChests;

    constructor(Dependencies memory _dependencies) {
        checkContract(_dependencies.chestManager);
        checkContract(_dependencies.sortedChests);

        chestManager = ChestManager(_dependencies.chestManager);
        sortedChests = ISortedChests(_dependencies.sortedChests);
    }

    function getMultipleSortedChests(address _asset, int _startIdx, uint256 _count)
        external view returns (CombinedChestData[] memory _chests)
    {
        uint256 startIdx;
        bool descend;

        if (_startIdx >= 0) {
            startIdx = uint(_startIdx);
            descend = true;
        } else {
            startIdx = uint(-(_startIdx + 1));
            descend = false;
        }

        uint256 sortedChestsSize = sortedChests.getSize(_asset);

        if (startIdx >= sortedChestsSize) {
            _chests = new CombinedChestData[](0);
        } else {
            uint256 maxCount = sortedChestsSize - startIdx;

            if (_count > maxCount) {
                _count = maxCount;
            }

            if (descend) {
                _chests = _getMultipleSortedChestsFromHead(_asset, startIdx, _count);
            } else {
                _chests = _getMultipleSortedChestsFromTail(_asset, startIdx, _count);
            }
        }
    }

    function _getMultipleSortedChestsFromHead(address _asset, uint256 _startIdx, uint256 _count)
        internal view returns (CombinedChestData[] memory _chests)
    {
        address currentChestowner = sortedChests.getFirst(_asset);

        for (uint256 idx = 0; idx < _startIdx; ++idx) {
            currentChestowner = sortedChests.getNext(_asset, currentChestowner);
        }

        _chests = new CombinedChestData[](_count);

        for (uint256 idx = 0; idx < _count; ++idx) {
            _chests[idx].owner = currentChestowner;
            (
                _chests[idx].debt,
                _chests[idx].coll,
                _chests[idx].stake,
                /* status */,
                /* arrayIndex */,
                /* interestIndex */
            ) = chestManager.Chests(_asset, currentChestowner);
            (
                _chests[idx].snapshotETH,
                _chests[idx].snapshotUSDSDebt
            ) = chestManager.rewardSnapshots(_asset, currentChestowner);

            currentChestowner = sortedChests.getNext(_asset, currentChestowner);
        }
    }

    function _getMultipleSortedChestsFromTail(address _asset, uint256 _startIdx, uint256 _count)
        internal view returns (CombinedChestData[] memory _chests)
    {
        address currentChestowner = sortedChests.getLast(_asset);

        for (uint256 idx = 0; idx < _startIdx; ++idx) {
            currentChestowner = sortedChests.getPrev(_asset, currentChestowner);
        }

        _chests = new CombinedChestData[](_count);

        for (uint256 idx = 0; idx < _count; ++idx) {
            _chests[idx].owner = currentChestowner;
            (
                _chests[idx].debt,
                _chests[idx].coll,
                _chests[idx].stake,
                /* status */,
                /* arrayIndex */,
                /* interestIndex */
            ) = chestManager.Chests(_asset, currentChestowner);
            (
                _chests[idx].snapshotETH,
                _chests[idx].snapshotUSDSDebt
            ) = chestManager.rewardSnapshots(_asset, currentChestowner);

            currentChestowner = sortedChests.getPrev(_asset, currentChestowner);
        }
    }
}
