// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/finance/VestingWallet.sol";

contract StablisVestingWallet is VestingWallet {

    uint256 private constant SIX_MONTHS = 60 * 60 * 24 * 30 * 6;
    uint256 private constant MAX_BPS = 100_00;

    uint256 private immutable unlockedAmountBPS;

    constructor(
        address _beneficiaryAddress,
        uint64 _durationSeconds,
        uint64 _cliffSeconds,
        uint64 _startTime,
        uint256 _unlockAmountBPS
    ) VestingWallet(_beneficiaryAddress, _getStartTime(_cliffSeconds, _startTime), _durationSeconds) {
        require(_durationSeconds >= SIX_MONTHS, "StablisVestingWallet: Duration must be at least half a year");
        require(_unlockAmountBPS <= MAX_BPS, "StablisVestingWallet: Unlock amount must be less than or equal to 100%");

        unlockedAmountBPS = _unlockAmountBPS;
    }

    function _getStartTime(
        uint64 _cliffSeconds,
        uint64 _startTime
    ) internal view returns (uint64) {
        return (_startTime == 0 ? uint64(block.timestamp) : _startTime) + _cliffSeconds;
    }

    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view override returns (uint256) {
        uint256 unlocked = totalAllocation * unlockedAmountBPS / MAX_BPS;
        uint256 locked;
        unchecked {
            locked = totalAllocation - unlocked;
        }

        if (timestamp < start()) {
            return unlocked;
        } else if (timestamp >= start() + duration()) {
            return totalAllocation;
        } else {
            uint256 vested;
            unchecked {
                vested = unlocked + (locked * (timestamp - start())) / duration();
            }
            return vested;
        }
    }
}
