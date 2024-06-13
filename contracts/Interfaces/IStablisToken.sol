// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "../Dependencies/IERC20.sol";
import "../Dependencies/IERC2612.sol";

interface IStablisToken is IERC20, IERC2612 {
    struct Dependencies {
        address communityIssuance;
        address stablisStaking;
        address usdsAirdrop;
        address vestingWalletFactory;
    }

    // --- Functions ---

    function sendToStablisStaking(address _sender, uint256 _amount) external;

    function getDeploymentStartTime() external view returns (uint256);
}
