// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IPool.sol";

interface IActivePool is IPool {
    // --- Structs ---
    struct Dependencies {
        address borrowerOperations;
        address chestManager;
        address collSurplusPool;
        address defaultPool;
        address stabilityPool;
    }
    // --- Events ---
    event ActivePoolUSDSDebtUpdated(address indexed _asset, uint256 _USDSDebt);
    event ActivePoolETHBalanceUpdated(address indexed _asset, uint256 _ETH);

    // --- Functions ---
    function sendETH(address _asset, address _account, uint256 _amount) external;
}
