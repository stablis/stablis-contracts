// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IDeposit.sol";

interface ICollSurplusPool is IDeposit {

    struct Dependencies {
        address activePool;
        address borrowerOperations;
        address chestManager;
    }

    // --- Events ---

    event CollBalanceUpdated(address indexed _asset, address indexed _account, uint256 _newBalance);
    event EtherSent(address indexed _asset, address _to, uint256 _amount);

    // --- Contract setters ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    ) external;

    function getETH(address _asset) external view returns (uint256);

    function getCollateral(address _asset, address _account) external view returns (uint256);

    function accountSurplus(address _asset, address _account, uint256 _amount) external;

    function claimColl(address _asset, address _account) external;
}
