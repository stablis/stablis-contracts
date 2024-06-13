// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "../Dependencies/IERC20.sol";

interface IBaseToken is IERC20 {

    // --- Functions ---

    function mint(uint256 _amount) external;

    function burn(uint256 _amount) external;
}
