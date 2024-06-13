// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface INitroPool {
    struct Settings {
        uint256 startTime;
        uint256 endTime;
        uint256 harvestStartTime;
        uint256 depositEndTime;
        uint256 lockDurationReq;
        uint256 lockEndReq;
        uint256 depositAmountReq;
        bool whitelist;
        string description;
    }

    function addRewards(uint256 amountToken1, uint256 amountToken2) external;
    function settings() external view returns (Settings memory);
}
