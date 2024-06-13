// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IUSDSAirdrop {
    struct Dependencies {
        address chestManager;
        address stablisToken;
    }

    function lastTimeRewardApplicable() external view returns (uint);

    function rewardPerToken() external view returns (uint);

    function earned(address _account) external view returns (uint);

    function getReward() external;

    function updateStake(address _asset, address _account, uint256 _newStake) external;

}
