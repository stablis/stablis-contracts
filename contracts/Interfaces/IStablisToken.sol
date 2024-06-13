// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "../Dependencies/IERC2612.sol";

interface IStablisToken is IERC20MetadataUpgradeable, IERC2612 {
    struct Dependencies {
        address communityIssuance;
        address stablisStaking;
        address usdsAirdrop;
        address vestingWalletFactory;
    }

    // --- Functions ---

    function sendToStablisStaking(address _sender, uint256 _amount) external;

    function getDeploymentStartTime() external view returns (uint256);

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);
}
