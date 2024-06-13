// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "../Dependencies/IERC2612.sol";

interface IUSDSToken is IERC20MetadataUpgradeable, IERC2612 {
    struct Dependencies {
        address borrowerOperations;
        address chestManager;
        address stabilityPool;
    }

    // --- Events ---

    event USDSTokenBalanceUpdated(address _user, uint256 _amount);

    // --- Functions ---

    function mint(address _account, uint256 _amount) external;

    function burn(address _account, uint256 _amount) external;

    function sendToPool(address _sender,  address poolAddress, uint256 _amount) external;

    function returnFromPool(address poolAddress, address user, uint256 _amount ) external;

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);
}
