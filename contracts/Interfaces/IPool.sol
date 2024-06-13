// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IDeposit.sol";

// Common interface for the Pools.
interface IPool is IDeposit {

    // --- Events ---

    event ETHBalanceUpdated(uint256 _newBalance);
    event USDSBalanceUpdated(uint256 _newBalance);
    event EtherSent(address _asset, address _to, uint256 _amount);

    // --- Functions ---

    function getETH(address _asset) external view returns (uint256);

    function getUSDSDebt(address _asset) external view returns (uint256);

    function increaseUSDSDebt(address _asset, uint256 _amount) external;

    function decreaseUSDSDebt(address _asset, uint256 _amount) external;
}
