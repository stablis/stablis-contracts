// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IPool.sol";


interface IDefaultPool is IPool {

    struct Dependencies {
        address activePool;
        address chestManager;
    }

    // --- Events ---

    event DefaultPoolUSDSDebtUpdated(address _asset, uint256 _USDSDebt);
    event DefaultPoolETHBalanceUpdated(address _asset, uint256 _ETH);

    // --- Functions ---

    function sendETHToActivePool(address _asset, uint256 _amount) external;
}
