// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IVestingWalletFactory {

    // --- Events ---
    event VestingWalletDeployedThroughFactory(address _vestingWalletAddress, address _beneficiary, uint64 _startTimestamp, uint64 _durationSeconds, address _deployer);

    // --- Functions ---

    function deployVestingWallet(address _beneficiary, uint256 _amount) external;
}
