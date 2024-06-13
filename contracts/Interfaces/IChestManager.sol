// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IStablisBase.sol";
import "./IStabilityPool.sol";
import "./IUSDSToken.sol";
import "./IStablisToken.sol";
import "./IStablisStaking.sol";

// Common interface for the Chest Manager.
interface IChestManager is IStablisBase {
    struct Dependencies {
        address activePool;
        address attributes;
        address borrowerOperations;
        address collSurplusPool;
        address defaultPool;
        address gasPool;
        address priceFeed;
        address sortedChests;
        address stabilityPool;
        address stablisStaking;
        address stablisToken;
        address usdsAirdrop;
        address usdsToken;
    }

    enum ChestManagerOperation {
        applyPendingRewards,
        liquidate,
        redeemCollateral
    }

    // --- Events ---

    event Liquidation(address indexed _asset, uint256 _liquidatedDebt, uint256 _liquidatedColl, uint256 _collGasCompensation, uint256 _USDSGasCompensation);
    event Redemption(address indexed _asset, uint256 _attemptedUSDSAmount, uint256 _actualUSDSAmount, uint256 _ETHSent, uint256 _ETHFee);
    event ChestUpdated(address indexed _asset, address indexed _borrower, uint256 _debt, uint256 _coll, uint256 _stake, ChestManagerOperation _operation);
    event ChestLiquidated(address indexed _asset, address indexed _borrower, uint256 _debt, uint256 _coll);
    event BaseRateUpdated(address indexed _asset, uint256 _baseRate);
    event LastFeeOpTimeUpdated(address indexed _asset, uint256 _lastFeeOpTime);
    event TotalStakesUpdated(address indexed _asset, uint256 _newTotalStakes);
    event SystemSnapshotsUpdated(address indexed _asset, uint256 _totalStakesSnapshot, uint256 _totalCollateralSnapshot);
    event LTermsUpdated(address indexed _asset, uint256 _L_ETH, uint256 _L_USDSDebt);
    event ChestSnapshotsUpdated(address indexed _asset, uint256 _L_ETH, uint256 _L_USDSDebt);
    event ChestIndexUpdated(address indexed _asset, address _borrower, uint256 _newIndex);

    // --- Functions ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    ) external;

    function stabilityPool() external view returns (IStabilityPool);
    function usdsToken() external view returns (IUSDSToken);
    function stablisToken() external view returns (IStablisToken);
    function stablisStaking() external view returns (IStablisStaking);

    function getChestOwnersCount(address _asset) external view returns (uint256);

    function getChestFromChestOwnersArray(address _asset, uint256 _index) external view returns (address);

    function getNominalICR(address _asset, address _borrower) external view returns (uint256);
    function getCurrentICR(address _asset, address _borrower, uint256 _price) external view returns (uint256);

    function liquidate(address _asset, address _borrower) external;

    function batchLiquidateChests(address _asset, address[] calldata _chestArray) external;

    function redeemCollateral(
        address _asset,
        uint256 _USDSAmount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFee
    ) external;

    function updateStakeAndTotalStakes(address _asset, address _borrower) external returns (uint256);

    function updateChestRewardSnapshots(address _asset, address _borrower) external;

    function addChestOwnerToArray(address _asset, address _borrower) external returns (uint256 index);

    function applyPendingRewards(address _asset, address _borrower) external;

    function getPendingETHReward(address _asset, address _borrower) external view returns (uint256);

    function getPendingUSDSDebtReward(address _asset, address _borrower) external view returns (uint256);

    function hasPendingRewards(address _asset, address _borrower) external view returns (bool);

    function getEntireDebtAndColl(address _asset, address _borrower) external view returns (
        uint256 debt,
        uint256 coll,
        uint256 pendingUSDSDebtReward,
        uint256 pendingETHReward
    );

    function closeChest(address _asset, address _borrower) external;

    function removeStake(address _asset, address _borrower) external;

    function getRedemptionRate(address _asset) external view returns (uint256);
    function getRedemptionRateWithDecay(address _asset) external view returns (uint256);

    function getRedemptionFeeWithDecay(address _asset, uint256 _ETHDrawn) external view returns (uint256);

    function getBorrowingRate(address _asset) external view returns (uint256);
    function getBorrowingRateWithDecay(address _asset) external view returns (uint256);

    function getBorrowingFee(address _asset, uint256 USDSDebt) external view returns (uint256);
    function getBorrowingFeeWithDecay(address _asset, uint256 _USDSDebt) external view returns (uint256);

    function decayBaseRateFromBorrowing(address _asset) external;

    function getChestStatus(address _asset, address _borrower) external view returns (uint256);

    function getChestStake(address _asset, address _borrower) external view returns (uint256);

    function getChestDebt(address _asset, address _borrower) external view returns (uint256);

    function getChestColl(address _asset, address _borrower) external view returns (uint256);

    function setChestStatus(address _asset, address _borrower, uint256 num) external;

    function increaseChestColl(address _asset, address _borrower, uint256 _collIncrease) external returns (uint256);

    function decreaseChestColl(address _asset, address _borrower, uint256 _collDecrease) external returns (uint256);

    function increaseChestDebt(address _asset, address _borrower, uint256 _debtIncrease) external returns (uint256);

    function decreaseChestDebt(address _asset, address _borrower, uint256 _collDecrease) external returns (uint256);

    function setChestInterestIndex(address _asset, address _borrower, uint256 _interestIndex) external;

    function getTCR(address _asset, uint256 _price) external view returns (uint256);

    function accrueActiveInterests(address _asset) external returns (uint256);
}
