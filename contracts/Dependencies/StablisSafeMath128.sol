// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// uint128 addition and subtraction, with overflow protection.

library StablisSafeMath128 {
    function add(uint128 a, uint128 b) internal pure returns (uint128) {
        uint128 c;
        unchecked {
            c = a + b;
        }
        require(c >= a, "StablisSafeMath128: addition overflow");
        return c;
    }

    function sub(uint128 a, uint128 b) internal pure returns (uint128) {
        require(b <= a, "StablisSafeMath128: subtraction overflow");
        uint128 c;
        unchecked {
            c = a - b;
        }
        return c;
    }
}
