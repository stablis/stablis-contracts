// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IDIA {
    function getValue(string memory key) external view returns (uint128, uint128);
}
