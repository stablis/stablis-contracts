// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IPriceFeed.sol";


interface IStablisBase {
    function priceFeed() external view returns (IPriceFeed);
}
