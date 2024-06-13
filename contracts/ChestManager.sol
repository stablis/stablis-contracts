// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./Interfaces/IChestManager.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IUSDSToken.sol";
import "./Interfaces/ISortedChests.sol";
import "./Interfaces/IStablisToken.sol";
import "./Interfaces/IStablisStaking.sol";
import "./Interfaces/IUSDSAirdrop.sol";

import "./Dependencies/StablisBase.sol";
import "./Dependencies/IERC20.sol";
import "./Dependencies/CheckContract.sol";

contract ChestManager is StablisBase, OwnableUpgradeable, CheckContract, IChestManager {
    using SafeMathUpgradeable for uint256;

    string constant public NAME = "ChestManager";

    // --- Connected contract declarations ---

    address public borrowerOperationsAddress;

    IStabilityPool public override stabilityPool;

    address public gasPoolAddress;

    ICollSurplusPool public collSurplusPool;

    IUSDSToken public override usdsToken;

    IStablisToken public override stablisToken;

    IStablisStaking public override stablisStaking;

    IUSDSAirdrop public usdsAirdrop;

    // A doubly linked list of Chests, sorted by their sorted by their collateral ratios
    ISortedChests public sortedChests;

    // --- Data structures ---

    uint256 constant public SECONDS_IN_ONE_MINUTE = 60;
    /*
     * Half-life of 12h. 12h = 720 min
     * (1/2) = d^720 => d = (1/2)^(1/720)
     */
    uint256 constant public MINUTE_DECAY_FACTOR = 999037758833783000;
    uint256 constant public REDEMPTION_FEE_FLOOR = DECIMAL_PRECISION / 1000 * 5; // 0.5%
    uint256 constant public MAX_BORROWING_FEE = DECIMAL_PRECISION / 100 * 5; // 5%

    // During bootstrap period redemptions are not allowed
    uint256 constant public BOOTSTRAP_PERIOD = 1 days;

    /*
    * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
    * Corresponds to (1 / ALPHA) in the white paper.
    */
    uint256 constant public BETA = 2;

    mapping(address => uint256) public baseRate;

    // The timestamp of the latest fee operation (redemption or new USDS issuance)
    mapping(address => uint256) public lastFeeOperationTime;

    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        closedByRedemption
    }

    // Store the necessary data for a chest
    struct Chest {
        uint256 debt;
        uint256 coll;
        uint256 stake;
        Status status;
        uint128 arrayIndex;
        uint256 activeInterestIndex;
    }

    mapping (address => mapping (address => Chest)) public Chests;

	mapping(address => uint256) public totalStakes;

    // Snapshot of the value of totalStakes, taken immediately after the latest liquidation
	mapping(address => uint256) public totalStakesSnapshot;

    // Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
	mapping(address => uint256) public totalCollateralSnapshot;

    /*
    * L_ETH and L_USDSDebt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
    *
    * An ETH gain of ( stake * [L_ETH - L_ETH(0)] )
    * A USDSDebt increase  of ( stake * [L_USDSDebt - L_USDSDebt(0)] )
    *
    * Where L_ETH(0) and L_USDSDebt(0) are snapshots of L_ETH and L_USDSDebt for the active Chest taken at the instant the stake was made
    */
	mapping(address => uint256) public L_ETH;
	mapping(address => uint256) public L_USDSDebt;

    // Map addresses with active chests to their RewardSnapshot. Asset > User > RewardSnapshot
    mapping(address => mapping(address => RewardSnapshot)) public rewardSnapshots;

    // Object containing the ETH and USDS snapshots for a given active chest
    struct RewardSnapshot { uint256 ETH; uint256 USDSDebt; }

    // Array of all active chest addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
	mapping(address => address[]) public ChestOwners;

    // Error trackers for the chest redistribution calculation
	mapping(address => uint256) public lastETHError_Redistribution;
	mapping(address => uint256) public lastUSDSDebtError_Redistribution;

    /*
    * --- Variable container structs for liquidations ---
    *
    * These structs are used to hold, return and assign variables inside the liquidation functions,
    * in order to avoid the error: "CompilerError: Stack too deep".
    **/

    struct LocalVariables_OuterLiquidationFunction {
        uint256 price;
        uint256 USDSInStabPool;
        uint256 liquidatedDebt;
        uint256 liquidatedColl;
    }

    struct LocalVariables_InnerSingleLiquidateFunction {
        uint256 collToLiquidate;
        uint256 pendingDebtReward;
        uint256 pendingCollReward;
    }

    struct LocalVariables_LiquidationSequence {
        uint256 remainingUSDSInStabPool;
        uint256 i;
        uint256 ICR;
        address user;
        uint256 entireSystemDebt;
        uint256 entireSystemColl;
        uint256 price;
    }

    struct LocalVariables_AssetBorrowerPrice {
        address _asset;
        address _borrower;
        uint256 _price;
    }

    struct LiquidationValues {
        uint256 entireChestDebt;
        uint256 entireChestColl;
        uint256 collGasCompensation;
        uint256 USDSGasCompensation;
        uint256 debtToOffset;
        uint256 collToSendToSP;
        uint256 debtToRedistribute;
        uint256 collToRedistribute;
        uint256 collSurplus;
    }

    struct LiquidationTotals {
        uint256 totalCollInSequence;
        uint256 totalDebtInSequence;
        uint256 totalCollGasCompensation;
        uint256 totalUSDSGasCompensation;
        uint256 totalDebtToOffset;
        uint256 totalCollToSendToSP;
        uint256 totalDebtToRedistribute;
        uint256 totalCollToRedistribute;
        uint256 totalCollSurplus;
    }

    struct ContractsCache {
        IActivePool activePool;
        IDefaultPool defaultPool;
        IUSDSToken usdsToken;
        IStablisStaking stablisStaking;
        ISortedChests sortedChests;
        ICollSurplusPool collSurplusPool;
        address gasPoolAddress;
    }
    // --- Variable container structs for redemptions ---

    struct RedemptionTotals {
        uint256 remainingUSDS;
        uint256 totalUSDSToRedeem;
        uint256 totalETHDrawn;
        uint256 ETHFee;
        uint256 ETHToSendToRedeemer;
        uint256 decayedBaseRate;
        uint256 price;
        uint256 totalUSDSSupplyAtStart;
    }

    struct SingleRedemptionValues {
        address asset;
        uint256 USDSLot;
        uint256 ETHLot;
        bool cancelledPartial;
    }

    // --- Dependency setter ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        override
        initializer
    {
        __Ownable_init();

        checkContract(_dependencies.activePool);
        checkContract(_dependencies.attributes);
        checkContract(_dependencies.borrowerOperations);
        checkContract(_dependencies.collSurplusPool);
        checkContract(_dependencies.defaultPool);
        checkContract(_dependencies.gasPool);
        checkContract(_dependencies.priceFeed);
        checkContract(_dependencies.sortedChests);
        checkContract(_dependencies.stabilityPool);
        checkContract(_dependencies.stablisStaking);
        checkContract(_dependencies.stablisToken);
        checkContract(_dependencies.usdsAirdrop);
        checkContract(_dependencies.usdsToken);

        activePool = IActivePool(_dependencies.activePool);
        attributes = IAttributes(_dependencies.attributes);
        borrowerOperationsAddress = _dependencies.borrowerOperations;
        collSurplusPool = ICollSurplusPool(_dependencies.collSurplusPool);
        defaultPool = IDefaultPool(_dependencies.defaultPool);
        gasPoolAddress = _dependencies.gasPool;
        priceFeed = IPriceFeed(_dependencies.priceFeed);
        sortedChests = ISortedChests(_dependencies.sortedChests);
        stabilityPool = IStabilityPool(_dependencies.stabilityPool);
        stablisStaking = IStablisStaking(_dependencies.stablisStaking);
        stablisToken = IStablisToken(_dependencies.stablisToken);
        usdsAirdrop = IUSDSAirdrop(_dependencies.usdsAirdrop);
        usdsToken = IUSDSToken(_dependencies.usdsToken);

        transferOwnership(_multiSig);
    }

    // --- Getters ---

    function getChestOwnersCount(address _asset) external view override returns (uint256) {
        return ChestOwners[_asset].length;
    }

    function getChestFromChestOwnersArray(address _asset, uint256 _index) external view override returns (address) {
        return ChestOwners[_asset][_index];
    }

    // --- Chest Liquidation functions ---

    // Single liquidation function. Closes the chest if its ICR is lower than the minimum collateral ratio.
    function liquidate(address _asset, address _borrower) external override {
        _requireChestIsActive(_asset, _borrower);

        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        batchLiquidateChests(_asset, borrowers);
    }

    // --- Inner single liquidation functions ---

    // Liquidate one chest
    function _liquidate(
		address _asset,
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        address _borrower,
        uint256 _USDSInStabPool
    )
        internal
        returns (LiquidationValues memory singleLiquidation)
    {
        LocalVariables_InnerSingleLiquidateFunction memory vars;

        (singleLiquidation.entireChestDebt,
        singleLiquidation.entireChestColl,
        vars.pendingDebtReward,
        vars.pendingCollReward) = getEntireDebtAndColl(_asset, _borrower);

        _movePendingChestRewardsToActivePool(_asset, _activePool, _defaultPool, vars.pendingDebtReward, vars.pendingCollReward);
        _removeStake(_asset, _borrower);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireChestColl);
        singleLiquidation.USDSGasCompensation = getUSDSGasCompensation();
        uint256 collToLiquidate = singleLiquidation.entireChestColl.sub(singleLiquidation.collGasCompensation);

        (singleLiquidation.debtToOffset,
        singleLiquidation.collToSendToSP,
        singleLiquidation.debtToRedistribute,
        singleLiquidation.collToRedistribute) = _getOffsetAndRedistributionVals(singleLiquidation.entireChestDebt, collToLiquidate, _USDSInStabPool);

        _closeChest(_asset, _borrower, Status.closedByLiquidation);
        emit ChestLiquidated(_asset, _borrower, singleLiquidation.entireChestDebt, singleLiquidation.entireChestColl);
        emit ChestUpdated(_asset, _borrower, 0, 0, 0, ChestManagerOperation.liquidate);
        return singleLiquidation;
    }

    /* In a full liquidation, returns the values for a chest's coll and debt to be offset, and coll and debt to be
    * redistributed to active chests.
    */
    function _getOffsetAndRedistributionVals
    (
        uint256 _debt,
        uint256 _coll,
        uint256 _USDSInStabPool
    )
        internal
        pure
        returns (uint256 debtToOffset, uint256 collToSendToSP, uint256 debtToRedistribute, uint256 collToRedistribute)
    {
        if (_USDSInStabPool > 0) {
        /*
        * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
        * between all active chests.
        *
        *  If the chest's debt is larger than the deposited USDS in the Stability Pool:
        *
        *  - Offset an amount of the chest's debt equal to the USDS in the Stability Pool
        *  - Send a fraction of the chest's collateral to the Stability Pool, equal to the fraction of its offset debt
        *
        */
            debtToOffset = StablisMath._min(_debt, _USDSInStabPool);
            collToSendToSP = _coll.mul(debtToOffset).div(_debt);
            debtToRedistribute = _debt.sub(debtToOffset);
            collToRedistribute = _coll.sub(collToSendToSP);
        } else {
            debtToOffset = 0;
            collToSendToSP = 0;
            debtToRedistribute = _debt;
            collToRedistribute = _coll;
        }
    }

    /*
    *  Get its offset coll/debt and ETH gas comp, and close the chest.
    */
    function _getCappedOffsetVals
    (
        uint256 _entireChestDebt,
        uint256 _entireChestColl,
        uint256 _price
    )
        internal
        view
        returns (LiquidationValues memory singleLiquidation)
    {
        singleLiquidation.entireChestDebt = _entireChestDebt;
        singleLiquidation.entireChestColl = _entireChestColl;
        uint256 cappedCollPortion = _entireChestDebt.mul(getMCR()).div(_price);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(cappedCollPortion);
        singleLiquidation.USDSGasCompensation = getUSDSGasCompensation();

        singleLiquidation.debtToOffset = _entireChestDebt;
        singleLiquidation.collToSendToSP = cappedCollPortion.sub(singleLiquidation.collGasCompensation);
        singleLiquidation.collSurplus = _entireChestColl.sub(cappedCollPortion);
        singleLiquidation.debtToRedistribute = 0;
        singleLiquidation.collToRedistribute = 0;
    }

    /*
    * Attempt to liquidate a custom list of chests provided by the caller.
    */
    function batchLiquidateChests(address _asset, address[] memory _chestArray) public override {
        require(_chestArray.length != 0, "Chest array must not be empty");
        _accrueActiveInterests(_asset);

        IActivePool activePoolCached = activePool;
        IDefaultPool defaultPoolCached = defaultPool;
        IStabilityPool stabilityPoolCached = stabilityPool;

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        vars.price = priceFeed.fetchPrice(_asset);
        vars.USDSInStabPool = stabilityPoolCached.getTotalUSDSDeposits();


        totals = _getTotalsFromBatchLiquidate(_asset, activePoolCached, defaultPoolCached, vars.price, vars.USDSInStabPool, _chestArray);
        require(totals.totalDebtInSequence > 0, "Nothing to liquidate");

        // Move liquidated ETH and USDS to the appropriate pools
        stabilityPoolCached.offset(_asset, totals.totalDebtToOffset, totals.totalCollToSendToSP);
        _redistributeDebtAndColl(_asset, activePoolCached, defaultPoolCached, totals.totalDebtToRedistribute, totals.totalCollToRedistribute);
        if (totals.totalCollSurplus > 0) {
            activePoolCached.sendETH(_asset, address(collSurplusPool), totals.totalCollSurplus);
        }

        // Update system snapshots
        _updateSystemSnapshots_excludeCollRemainder(_asset, activePoolCached, totals.totalCollGasCompensation);

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(totals.totalCollSurplus);
        emit Liquidation(_asset, vars.liquidatedDebt, vars.liquidatedColl, totals.totalCollGasCompensation, totals.totalUSDSGasCompensation);

        // Send gas compensation to caller
        _sendGasCompensation(_asset, activePoolCached, msg.sender, totals.totalUSDSGasCompensation, totals.totalCollGasCompensation);
    }

    function _getTotalsFromBatchLiquidate
    (
        address _asset,
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        uint256 _price,
        uint256 _USDSInStabPool,
        address[] memory _chestArray
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingUSDSInStabPool = _USDSInStabPool;

        for (vars.i = 0; vars.i < _chestArray.length; vars.i++) {
            vars.user = _chestArray[vars.i];
            vars.ICR = getCurrentICR(_asset, vars.user, _price);

            if (vars.ICR < getMCR()) {
                singleLiquidation = _liquidate(_asset, _activePool, _defaultPool, vars.user, vars.remainingUSDSInStabPool);
                vars.remainingUSDSInStabPool = vars.remainingUSDSInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            }
        }
    }

    // --- Liquidation helper functions ---

    function _addLiquidationValuesToTotals(LiquidationTotals memory oldTotals, LiquidationValues memory singleLiquidation)
    internal pure returns(LiquidationTotals memory newTotals) {

        // Tally all the values with their respective running totals
        newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation.add(singleLiquidation.collGasCompensation);
        newTotals.totalUSDSGasCompensation = oldTotals.totalUSDSGasCompensation.add(singleLiquidation.USDSGasCompensation);
        newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence.add(singleLiquidation.entireChestDebt);
        newTotals.totalCollInSequence = oldTotals.totalCollInSequence.add(singleLiquidation.entireChestColl);
        newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset.add(singleLiquidation.debtToOffset);
        newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP.add(singleLiquidation.collToSendToSP);
        newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute.add(singleLiquidation.debtToRedistribute);
        newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute.add(singleLiquidation.collToRedistribute);
        newTotals.totalCollSurplus = oldTotals.totalCollSurplus.add(singleLiquidation.collSurplus);

        return newTotals;
    }

    function _sendGasCompensation(address _asset, IActivePool _activePool, address _liquidator, uint256 _USDS, uint256 _ETH) internal {
        if (_USDS > 0) {
            usdsToken.returnFromPool(gasPoolAddress, _liquidator, _USDS);
        }

        if (_ETH > 0) {
            _activePool.sendETH(_asset, _liquidator, _ETH);
        }
    }

    // Move a Chest's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
    function _movePendingChestRewardsToActivePool(address _asset, IActivePool _activePool, IDefaultPool _defaultPool, uint256 _USDS, uint256 _ETH) internal {
        _defaultPool.decreaseUSDSDebt(_asset, _USDS);
        _activePool.increaseUSDSDebt(_asset, _USDS);
        _defaultPool.sendETHToActivePool(_asset, _ETH);
    }

    // --- Redemption functions ---

    // Redeem as much collateral as possible from _borrower's Chest in exchange for USDS up to _maxUSDSamount
    function _redeemCollateralFromChest(
        address _asset,
        ContractsCache memory _contractsCache,
        address _borrower,
        uint256 _maxUSDSamount,
        uint256 _price,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR
    )
        internal returns (SingleRedemptionValues memory singleRedemption)
    {
        LocalVariables_AssetBorrowerPrice memory vars = LocalVariables_AssetBorrowerPrice(_asset, _borrower, _price);
        uint256 USDS_GAS_COMPENSATION = getUSDSGasCompensation();

        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Chest minus the liquidation reserve
        singleRedemption.USDSLot = StablisMath._min(_maxUSDSamount, Chests[vars._asset][vars._borrower].debt.sub(USDS_GAS_COMPENSATION));

        // Get the ETHLot of equivalent value in USD
        singleRedemption.ETHLot = singleRedemption.USDSLot.mul(DECIMAL_PRECISION).div(_price);

        // Decrease the debt and collateral of the current Chest according to the USDS lot and corresponding ETH to send
        uint256 newDebt = (Chests[vars._asset][vars._borrower].debt).sub(singleRedemption.USDSLot);
        uint256 newColl = (Chests[vars._asset][vars._borrower].coll).sub(singleRedemption.ETHLot);

        if (newDebt == USDS_GAS_COMPENSATION) {
            // No debt left in the Chest (except for the liquidation reserve), therefore the chest gets closed
            _removeStake(vars._asset, vars._borrower);
            _closeChest(vars._asset, vars._borrower, Status.closedByRedemption);
            _redeemCloseChest(vars._asset, _contractsCache, vars._borrower, USDS_GAS_COMPENSATION, newColl);
            emit ChestUpdated(vars._asset, vars._borrower, 0, 0, 0, ChestManagerOperation.redeemCollateral);

        } else {
            uint256 newNICR = StablisMath._computeNominalCR(newColl, newDebt);

            /*
            * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
            * certainly result in running out of gas.
            *
            * If the resultant net debt of the partial is less than the minimum, net debt we bail.
            */
            uint256 icrError = newNICR > _partialRedemptionHintNICR ? newNICR - _partialRedemptionHintNICR : _partialRedemptionHintNICR - newNICR;
            if (icrError > 5e14 || _getNetDebt(newDebt) < getMinNetDebt()) {
                singleRedemption.cancelledPartial = true;
                return singleRedemption;
            }

            _contractsCache.sortedChests.reInsert(vars._asset, vars._borrower, newNICR, _upperPartialRedemptionHint, _lowerPartialRedemptionHint);

            Chests[vars._asset][vars._borrower].debt = newDebt;
            Chests[vars._asset][vars._borrower].coll = newColl;
            usdsAirdrop.updateStake(vars._asset, vars._borrower, newDebt);
            _updateStakeAndTotalStakes(vars._asset, vars._borrower);

            emit ChestUpdated(
                vars._asset,
                vars._borrower,
                newDebt, newColl,
                Chests[vars._asset][vars._borrower].stake,
                ChestManagerOperation.redeemCollateral
            );
        }

        return singleRedemption;
    }

    /*
    * Called when a full redemption occurs, and closes the chest.
    * The redeemer swaps (debt - liquidation reserve) USDS for (debt - liquidation reserve) worth of ETH, so the USDS liquidation reserve left corresponds to the remaining debt.
    * In order to close the chest, the USDS liquidation reserve is burned, and the corresponding debt is removed from the active pool.
    * The debt recorded on the chest's struct is zero'd elswhere, in _closeChest.
    * Any surplus ETH left in the chest, is sent to the Coll surplus pool, and can be later claimed by the borrower.
    */
    function _redeemCloseChest(address _asset, ContractsCache memory _contractsCache, address _borrower, uint256 _USDS, uint256 _ETH) internal {
        _contractsCache.usdsToken.burn(gasPoolAddress, _USDS);
        // Update Active Pool USDS, and send ETH to account
        _contractsCache.activePool.decreaseUSDSDebt(_asset, _USDS);

        // send ETH from Active Pool to CollSurplus Pool
        _contractsCache.collSurplusPool.accountSurplus(_asset, _borrower, _ETH);
        _contractsCache.activePool.sendETH(_asset, address(_contractsCache.collSurplusPool), _ETH);
    }

    function _isValidFirstRedemptionHint(address _asset, ISortedChests _sortedChests, address _firstRedemptionHint, uint256 _price) internal view returns (bool) {
        uint256 MCR = getMCR();
        if (_firstRedemptionHint == address(0) ||
            !_sortedChests.contains(_asset, _firstRedemptionHint) ||
            getCurrentICR(_asset, _firstRedemptionHint, _price) < MCR
        ) {
            return false;
        }

        address nextChest = _sortedChests.getNext(_asset, _firstRedemptionHint);
        return nextChest == address(0) || getCurrentICR(_asset, nextChest, _price) < MCR;
    }

    /* Send _USDSamount USDS to the system and redeem the corresponding amount of collateral from as many Chests as are needed to fill the redemption
    * request.  Applies pending rewards to a Chest before reducing its debt and coll.
    *
    * Note that if _amount is very large, this function can run out of gas, specially if traversed chests are small. This can be easily avoided by
    * splitting the total _amount in appropriate chunks and calling the function multiple times.
    *
    * Param `_maxIterations` can also be provided, so the loop through Chests is capped (if it’s zero, it will be ignored).This makes it easier to
    * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
    * of the chest list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
    * costs can vary.
    *
    * All Chests that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
    * If the last Chest does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
    * A frontend should use getRedemptionHints() to calculate what the ICR of this Chest will be after redemption, and pass a hint for its position
    * in the sortedChests list along with the ICR value that the hint was found for.
    *
    * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
    * is very likely that the last (partially) redeemed Chest would end up with a different ICR than what the hint is for. In this case the
    * redemption will stop after the last completely redeemed Chest and the sender will keep the remaining USDS amount, which they can attempt
    * to redeem later.
    */
    function redeemCollateral(
        address _asset,
        uint256 _USDSamount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    )
        external
        override
    {
        ContractsCache memory contractsCache = ContractsCache(
            activePool,
            defaultPool,
            usdsToken,
            stablisStaking,
            sortedChests,
            collSurplusPool,
            gasPoolAddress
        );
        RedemptionTotals memory totals;
        _requireValidMaxFeePercentage(_maxFeePercentage);
        _requireAfterBootstrapPeriod();
        totals.price = priceFeed.fetchPrice(_asset);
        _requireTCRoverMCR(_asset, totals.price);
        _requireAmountGreaterThanZero(_USDSamount);
        _requireUSDSBalanceCoversRedemption(contractsCache.usdsToken, msg.sender, _USDSamount);

        totals.totalUSDSSupplyAtStart = getEntireSystemDebt(_asset);
        // Confirm redeemer's balance is less than total USDS supply
        assert(contractsCache.usdsToken.balanceOf(msg.sender) >= _USDSamount && _USDSamount <= totals.totalUSDSSupplyAtStart);

        totals.remainingUSDS = _USDSamount;
        address currentBorrower;

        if (_isValidFirstRedemptionHint(_asset, contractsCache.sortedChests, _firstRedemptionHint, totals.price)) {
            currentBorrower = _firstRedemptionHint;
        } else {
            currentBorrower = contractsCache.sortedChests.getLast(_asset);
            // Find the first chest with ICR >= MCR
            uint256 MCR = getMCR();
            while (currentBorrower != address(0) && getCurrentICR(_asset, currentBorrower, totals.price) < MCR) {
                currentBorrower = contractsCache.sortedChests.getPrev(_asset, currentBorrower);
            }
        }

        // Loop through the Chests starting from the one with lowest collateral ratio until _amount of USDS is exchanged for collateral
        if (_maxIterations == 0) { _maxIterations = type(uint256).max; }
        while (currentBorrower != address(0) && totals.remainingUSDS > 0 && _maxIterations > 0) {
            _maxIterations--;
            // Save the address of the Chest preceding the current one, before potentially modifying the list
            address nextUserToCheck = contractsCache.sortedChests.getPrev(_asset, currentBorrower);

            _applyPendingRewards(_asset, contractsCache.activePool, contractsCache.defaultPool, currentBorrower);

            SingleRedemptionValues memory singleRedemption = _redeemCollateralFromChest(
                _asset,
                contractsCache,
                currentBorrower,
                totals.remainingUSDS,
                totals.price,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint,
                _partialRedemptionHintNICR
            );

            if (singleRedemption.cancelledPartial) break; // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last Chest
            totals.totalUSDSToRedeem  = totals.totalUSDSToRedeem.add(singleRedemption.USDSLot);
            totals.totalETHDrawn = totals.totalETHDrawn.add(singleRedemption.ETHLot);

            totals.remainingUSDS = totals.remainingUSDS.sub(singleRedemption.USDSLot);
            currentBorrower = nextUserToCheck;
        }
        require(totals.totalETHDrawn > 0, "Unable to redeem any amount");

        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
        // Use the saved total USDS supply value, from before it was reduced by the redemption.
        _updateBaseRateFromRedemption(_asset, totals.totalETHDrawn, totals.price, totals.totalUSDSSupplyAtStart);

        // Calculate the ETH fee
        totals.ETHFee = _getRedemptionFee(_asset, totals.totalETHDrawn);

        _requireUserAcceptsFee(totals.ETHFee, totals.totalETHDrawn, _maxFeePercentage);

        // Send the ETH fee to the stablis staking contract
        contractsCache.activePool.sendETH(_asset, address(contractsCache.stablisStaking), totals.ETHFee);
        contractsCache.stablisStaking.increaseF_Asset(_asset, totals.ETHFee);

        totals.ETHToSendToRedeemer = totals.totalETHDrawn.sub(totals.ETHFee);

        emit Redemption(_asset, _USDSamount, totals.totalUSDSToRedeem, totals.totalETHDrawn, totals.ETHFee);

        // Burn the total USDS that is cancelled with debt, and send the redeemed ETH to msg.sender
        contractsCache.usdsToken.burn(msg.sender, totals.totalUSDSToRedeem);
        // Update Active Pool USDS, and send ETH to account
        contractsCache.activePool.decreaseUSDSDebt(_asset, totals.totalUSDSToRedeem);
        contractsCache.activePool.sendETH(_asset, msg.sender, totals.ETHToSendToRedeemer);
    }

    // --- Helper functions ---

    // Return the nominal collateral ratio (ICR) of a given Chest, without the price. Takes a chest's pending coll and debt rewards from redistributions into account.
    function getNominalICR(address _asset, address _borrower) public view override returns (uint256) {
        (uint256 currentETH, uint256 currentUSDSDebt) = _getCurrentChestAmounts(_asset, _borrower);

        uint256 NICR = StablisMath._computeNominalCR(currentETH, currentUSDSDebt);
        return NICR;
    }

    // Return the current collateral ratio (ICR) of a given Chest. Takes a chest's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(address _asset, address _borrower, uint256 _price) public view override returns (uint256) {
        (uint256 currentETH, uint256 currentUSDSDebt) = _getCurrentChestAmounts(_asset, _borrower);

        uint256 ICR = StablisMath._computeCR(currentETH, currentUSDSDebt, _price);
        return ICR;
    }

    function _getCurrentChestAmounts(address _asset, address _borrower) internal view returns (uint256, uint256) {
        uint256 pendingETHReward = getPendingETHReward(_asset, _borrower);
        uint256 pendingUSDSDebtReward = getPendingUSDSDebtReward(_asset, _borrower);

        uint256 currentETH = Chests[_asset][_borrower].coll.add(pendingETHReward);
        uint256 currentUSDSDebt = Chests[_asset][_borrower].debt.add(pendingUSDSDebtReward);

        return (currentETH, currentUSDSDebt);
    }

    function applyPendingRewards(address _asset, address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        _applyPendingRewards(_asset, activePool, defaultPool, _borrower);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions as well as accrued interests, to their Chest
    function _applyPendingRewards(address _asset, IActivePool _activePool, IDefaultPool _defaultPool, address _borrower) internal {
        Chest storage chest = Chests[_asset][_borrower];
        _requireChestIsActive(_asset, _borrower);

        uint256 chestInterestIndex = chest.activeInterestIndex;
        uint256 currentInterestIndex = _accrueActiveInterests(_asset);
        uint256 debt = chest.debt;

        if (chestInterestIndex < currentInterestIndex) {
            debt = (debt * currentInterestIndex) / chestInterestIndex;
            chest.activeInterestIndex = currentInterestIndex;
        }

        if (hasPendingRewards(_asset, _borrower)) {
            // Compute pending rewards
            uint256 pendingETHReward = getPendingETHReward(_asset, _borrower);
            uint256 pendingUSDSDebtReward = getPendingUSDSDebtReward(_asset, _borrower);

            // Apply pending rewards to chest's state
            chest.coll = chest.coll.add(pendingETHReward);
            debt = debt.add(pendingUSDSDebtReward);

            _updateChestRewardSnapshots(_asset, _borrower);
            // Transfer from DefaultPool to ActivePool
            _movePendingChestRewardsToActivePool(_asset, _activePool, _defaultPool, pendingUSDSDebtReward, pendingETHReward);
        }
        chest.debt = debt;

        usdsAirdrop.updateStake(_asset, _borrower, chest.debt);
    }

    function accrueActiveInterests(address _asset) external override returns (uint256){
        _requireCallerIsBOorAttributes();
        return _accrueActiveInterests(_asset);
    }

    function _accrueActiveInterests(address _asset) internal returns (uint256) {
        (uint256 currentInterestIndex, uint256 interestFactor) = _calculateInterestIndex(_asset);

        if (interestFactor > 0) {
            uint256 activeInterests = StablisMath.mulDiv(activePool.getUSDSDebt(_asset), interestFactor, attributes.getInterestPrecision());
            activePool.increaseUSDSDebt(_asset, activeInterests);
            usdsToken.mint(address(stablisStaking), activeInterests);
            stablisStaking.increaseF_Asset(address(usdsToken), activeInterests);
            attributes.setActiveInterestIndex(_asset, currentInterestIndex);
            attributes.setLastActiveIndexUpdate(_asset, block.timestamp);
        }
        return currentInterestIndex;
    }

    // Update borrower's snapshots of L_ETH and L_USDSDebt to reflect the current values
    function updateChestRewardSnapshots(address _asset, address _borrower) external override {
        _requireCallerIsBorrowerOperations();
       return _updateChestRewardSnapshots(_asset, _borrower);
    }

    function _updateChestRewardSnapshots(address _asset, address _borrower) internal {
        rewardSnapshots[_asset][_borrower].ETH = L_ETH[_asset];
        rewardSnapshots[_asset][_borrower].USDSDebt = L_USDSDebt[_asset];
        emit ChestSnapshotsUpdated(_asset, L_ETH[_asset], L_USDSDebt[_asset]);
    }

    // Get the borrower's pending accumulated ETH reward, earned by their stake
    function getPendingETHReward(address _asset, address _borrower) public view override returns (uint256) {
        uint256 snapshotETH = rewardSnapshots[_asset][_borrower].ETH;
        uint256 rewardPerUnitStaked = L_ETH[_asset].sub(snapshotETH);

        if ( rewardPerUnitStaked == 0 || Chests[_asset][_borrower].status != Status.active) { return 0; }

        uint256 stake = Chests[_asset][_borrower].stake;

        uint256 pendingETHReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

        return pendingETHReward;
    }

    // Get the borrower's pending accumulated USDS reward, earned by their stake
    function getPendingUSDSDebtReward(address _asset, address _borrower) public view override returns (uint256) {
        uint256 snapshotUSDSDebt = rewardSnapshots[_asset][_borrower].USDSDebt;
        uint256 rewardPerUnitStaked = L_USDSDebt[_asset].sub(snapshotUSDSDebt);

        if ( rewardPerUnitStaked == 0 || Chests[_asset][_borrower].status != Status.active) { return 0; }

        uint256 stake =  Chests[_asset][_borrower].stake;

        uint256 pendingUSDSDebtReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

        return pendingUSDSDebtReward;
    }

    function hasPendingRewards(address _asset, address _borrower) public view override returns (bool) {
        /*
        * A Chest has pending rewards if its snapshot is less than the current rewards per-unit-staked sum:
        * this indicates that rewards have occured since the snapshot was made, and the user therefore has
        * pending rewards
        */
        if (Chests[_asset][_borrower].status != Status.active) {return false;}

        return (rewardSnapshots[_asset][_borrower].ETH < L_ETH[_asset]);
    }

    // Return the Chests entire debt and coll, including pending rewards from redistributions and accrued interests.
    function getEntireDebtAndColl(
        address _asset,
        address _borrower
    )
        public
        view
        override
        returns (uint256 debt, uint256 coll, uint256 pendingUSDSDebtReward, uint256 pendingETHReward)
    {
        if (Chests[_asset][_borrower].status != Status.active) { return (0, 0, 0, 0); }
        debt = Chests[_asset][_borrower].debt;
        coll = Chests[_asset][_borrower].coll;
        uint256 activeInterestIndex = Chests[_asset][_borrower].activeInterestIndex;

        pendingUSDSDebtReward = getPendingUSDSDebtReward(_asset, _borrower);
        pendingETHReward = getPendingETHReward(_asset, _borrower);

        // Accrued chest interest for correct liquidation values. This assumes the index to be updated.
        (uint256 currentIndex, ) = _calculateInterestIndex(_asset);
        debt = (debt * currentIndex) / activeInterestIndex;

        debt = debt.add(pendingUSDSDebtReward);
        coll = coll.add(pendingETHReward);
    }

    function removeStake(address _asset, address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _removeStake(_asset, _borrower);
    }

    // Remove borrower's stake from the totalStakes sum, and set their stake to 0
    function _removeStake(address _asset, address _borrower) internal {
        uint256 stake = Chests[_asset][_borrower].stake;
        totalStakes[_asset] = totalStakes[_asset].sub(stake);
        Chests[_asset][_borrower].stake = 0;
    }

    function updateStakeAndTotalStakes(address _asset, address _borrower) external override returns (uint256) {
        _requireCallerIsBorrowerOperations();
        return _updateStakeAndTotalStakes(_asset, _borrower);
    }

    // Update borrower's stake based on their latest collateral value
    function _updateStakeAndTotalStakes(address _asset, address _borrower) internal returns (uint256) {
        uint256 newStake = _computeNewStake(_asset, Chests[_asset][_borrower].coll);
        uint256 oldStake = Chests[_asset][_borrower].stake;
        Chests[_asset][_borrower].stake = newStake;

        totalStakes[_asset] = totalStakes[_asset].sub(oldStake).add(newStake);
        emit TotalStakesUpdated(_asset, totalStakes[_asset]);

        return newStake;
    }

    // Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
    function _computeNewStake(address _asset, uint256 _coll) internal view returns (uint256) {
        uint256 stake;
        if (totalCollateralSnapshot[_asset] == 0) {
            stake = _coll;
        } else {
            /*
            * The following assert() holds true because:
            * - The system always contains >= 1 chest
            * - When we close or liquidate a chest, we redistribute the pending rewards, so if all chests were closed/liquidated,
            * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
            */
            assert(totalStakesSnapshot[_asset] > 0);
            stake = _coll.mul(totalStakesSnapshot[_asset]).div(totalCollateralSnapshot[_asset]);
        }
        return stake;
    }

    function _redistributeDebtAndColl(address _asset, IActivePool _activePool, IDefaultPool _defaultPool, uint256 _debt, uint256 _coll) internal {
        if (_debt == 0) { return; }

        /*
        * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
        * error correction, to keep the cumulative error low in the running totals L_ETH and L_USDSDebt:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint256 ETHNumerator = _coll.mul(DECIMAL_PRECISION).add(lastETHError_Redistribution[_asset]);
        uint256 USDSDebtNumerator = _debt.mul(DECIMAL_PRECISION).add(lastUSDSDebtError_Redistribution[_asset]);

        // Get the per-unit-staked terms
        uint256 ETHRewardPerUnitStaked = ETHNumerator.div(totalStakes[_asset]);
        uint256 USDSDebtRewardPerUnitStaked = USDSDebtNumerator.div(totalStakes[_asset]);

        lastETHError_Redistribution[_asset] = ETHNumerator.sub(ETHRewardPerUnitStaked.mul(totalStakes[_asset]));
        lastUSDSDebtError_Redistribution[_asset] = USDSDebtNumerator.sub(USDSDebtRewardPerUnitStaked.mul(totalStakes[_asset]));

        // Add per-unit-staked terms to the running totals
        L_ETH[_asset] = L_ETH[_asset].add(ETHRewardPerUnitStaked);
        L_USDSDebt[_asset] = L_USDSDebt[_asset].add(USDSDebtRewardPerUnitStaked);

        emit LTermsUpdated(_asset, L_ETH[_asset], L_USDSDebt[_asset]);

        // Transfer coll and debt from ActivePool to DefaultPool
        _activePool.decreaseUSDSDebt(_asset, _debt);
        _defaultPool.increaseUSDSDebt(_asset, _debt);
        _activePool.sendETH(_asset, address(_defaultPool), _coll);
    }

    function closeChest(address _asset, address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _closeChest(_asset, _borrower, Status.closedByOwner);
    }

    function _closeChest(address _asset, address _borrower, Status closedStatus) internal {
        assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

        uint256 ChestOwnersArrayLength = ChestOwners[_asset].length;
        _requireMoreThanOneChestInSystem(_asset, ChestOwnersArrayLength);

        Chests[_asset][_borrower].status = closedStatus;
        Chests[_asset][_borrower].coll = 0;
        Chests[_asset][_borrower].debt = 0;
        Chests[_asset][_borrower].activeInterestIndex = 0;

        rewardSnapshots[_asset][_borrower].ETH = 0;
        rewardSnapshots[_asset][_borrower].USDSDebt = 0;

        usdsAirdrop.updateStake(_asset, _borrower, 0);
        _removeChestOwner(_asset, _borrower, ChestOwnersArrayLength);
        sortedChests.remove(_asset, _borrower);
    }

    /*
    * Updates snapshots of system total stakes and total collateral, excluding a given collateral remainder from the calculation.
    * Used in a liquidation sequence.
    *
    * The calculation excludes a portion of collateral that is in the ActivePool:
    *
    * the total ETH gas compensation from the liquidation sequence
    *
    * The ETH as compensation must be excluded as it is always sent out at the very end of the liquidation sequence.
    */
    function _updateSystemSnapshots_excludeCollRemainder(address _asset, IActivePool _activePool, uint256 _collRemainder) internal {
        totalStakesSnapshot[_asset] = totalStakes[_asset];

        uint256 activeColl = _activePool.getETH(_asset);
        uint256 liquidatedColl = defaultPool.getETH(_asset);
        totalCollateralSnapshot[_asset] = activeColl.sub(_collRemainder).add(liquidatedColl);

        emit SystemSnapshotsUpdated(_asset, totalStakesSnapshot[_asset], totalCollateralSnapshot[_asset]);
    }

    // Push the owner's address to the Chest owners list, and record the corresponding array index on the Chest struct
    function addChestOwnerToArray(address _asset, address _borrower) external override returns (uint256 index) {
        _requireCallerIsBorrowerOperations();
        return _addChestOwnerToArray(_asset, _borrower);
    }

    function _addChestOwnerToArray(address _asset, address _borrower) internal returns (uint128 index) {
        /* Max array size is 2**128 - 1, i.e. ~3e30 chests. No risk of overflow, since chests have minimum USDS
        debt of liquidation reserve plus MIN_NET_DEBT. 3e30 USDS dwarfs the value of all wealth in the world ( which is < 1e15 USD). */

        // Push the Chestowner to the array
        ChestOwners[_asset].push(_borrower);

        // Record the index of the new Chestowner on their Chest struct
        index = uint128(ChestOwners[_asset].length.sub(1));
        Chests[_asset][_borrower].arrayIndex = index;

        return index;
    }

    /*
    * Remove a Chest owner from the ChestOwners array, not preserving array order. Removing owner 'B' does the following:
    * [A B C D E] => [A E C D], and updates E's Chest struct to point to its new array index.
    */
    function _removeChestOwner(address _asset, address _borrower, uint256 ChestOwnersArrayLength) internal {
        Status chestStatus = Chests[_asset][_borrower].status;
        // It’s set in caller function `_closeChest`
        assert(chestStatus != Status.nonExistent && chestStatus != Status.active);

        uint128 index = Chests[_asset][_borrower].arrayIndex;
        uint256 length = ChestOwnersArrayLength;
        uint256 idxLast = length.sub(1);

        assert(index <= idxLast);

        address addressToMove = ChestOwners[_asset][idxLast];

        ChestOwners[_asset][index] = addressToMove;
        Chests[_asset][addressToMove].arrayIndex = index;
        emit ChestIndexUpdated(_asset, addressToMove, index);

        ChestOwners[_asset].pop();
    }

    // --- TCR functions ---

    function getTCR(address _asset, uint256 _price) external view override returns (uint256) {
        return _getTCR(_asset, _price);
    }

    // --- Redemption fee functions ---

    /*
    * This function has two impacts on the baseRate state variable:
    * 1) decays the baseRate based on time passed since last redemption or USDS borrowing operation.
    * then,
    * 2) increases the baseRate based on the amount redeemed, as a proportion of total supply
    */
    function _updateBaseRateFromRedemption(address _asset, uint256 _ETHDrawn,  uint256 _price, uint256 _totalUSDSSupply) internal returns (uint256) {
        uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);

        /* Convert the drawn ETH back to USDS at face value rate (1 USDS:1 USD), in order to get
        * the fraction of total supply that was redeemed at face value. */
        uint256 redeemedUSDSFraction = _ETHDrawn.mul(_price).div(_totalUSDSSupply);

        uint256 newBaseRate = decayedBaseRate.add(redeemedUSDSFraction.div(BETA));
        newBaseRate = StablisMath._min(newBaseRate, DECIMAL_PRECISION); // cap baseRate at a maximum of 100%
        //assert(newBaseRate <= DECIMAL_PRECISION); // This is already enforced in the line above
        assert(newBaseRate > 0); // Base rate is always non-zero after redemption

        // Update the baseRate state variable
        baseRate[_asset] = newBaseRate;
        emit BaseRateUpdated(_asset, newBaseRate);

        _updateLastFeeOpTime(_asset);

        return newBaseRate;
    }

    function getRedemptionRate(address _asset) public view override returns (uint256) {
        return _calcRedemptionRate(baseRate[_asset]);
    }

    function getRedemptionRateWithDecay(address _asset) public view override returns (uint256) {
        return _calcRedemptionRate(_calcDecayedBaseRate(_asset));
    }

    function _calcRedemptionRate(uint256 _baseRate) internal pure returns (uint256) {
        return StablisMath._min(
            REDEMPTION_FEE_FLOOR.add(_baseRate),
            DECIMAL_PRECISION // cap at a maximum of 100%
        );
    }

    function _getRedemptionFee(address _asset, uint256 _ETHDrawn) internal view returns (uint256) {
        return _calcRedemptionFee(_asset, getRedemptionRate(_asset), _ETHDrawn);
    }

    function getRedemptionFeeWithDecay(address _asset, uint256 _ETHDrawn) external view override returns (uint256) {
        return _calcRedemptionFee(_asset, getRedemptionRateWithDecay(_asset), _ETHDrawn);
    }

    function _calcRedemptionFee(address _asset, uint256 _redemptionRate, uint256 _ETHDrawn) internal view returns (uint256) {
        uint256 redemptionFee = _redemptionRate.mul(_ETHDrawn).div(DECIMAL_PRECISION);
        if (_asset != address(0)) {
            uint8 nativeDecimals = IERC20(_asset).decimals();
            if (nativeDecimals < 18) {
                redemptionFee = StablisMath.decimalsCorrectionWithPadding(redemptionFee, nativeDecimals);
            }
        }
        require(redemptionFee < _ETHDrawn, "Fee exceeds redeemed amount");
        return redemptionFee;
    }

    // --- Borrowing fee functions ---

    function getBorrowingRate(address _asset) public view override returns (uint256) {
        return _calcBorrowingRate(baseRate[_asset]);
    }

    function getBorrowingRateWithDecay(address _asset) public view override returns (uint256) {
        return _calcBorrowingRate(_calcDecayedBaseRate(_asset));
    }

    function _calcBorrowingRate(uint256 _baseRate) internal view returns (uint256) {
        return StablisMath._min(
            getBorrowingFeeFloor().add(_baseRate),
            MAX_BORROWING_FEE
        );
    }

    function getBorrowingFee(address _asset, uint256 _USDSDebt) external view override returns (uint256) {
        return _calcBorrowingFee(getBorrowingRate(_asset), _USDSDebt);
    }

    function getBorrowingFeeWithDecay(address _asset, uint256 _USDSDebt) external view override returns (uint256) {
        return _calcBorrowingFee(getBorrowingRateWithDecay(_asset), _USDSDebt);
    }

    function _calcBorrowingFee(uint256 _borrowingRate, uint256 _USDSDebt) internal pure returns (uint256) {
        return _borrowingRate.mul(_USDSDebt).div(DECIMAL_PRECISION);
    }


    // Updates the baseRate state variable based on time elapsed since the last redemption or USDS borrowing operation.
    function decayBaseRateFromBorrowing(address _asset) external override {
        _requireCallerIsBorrowerOperations();

        uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);
        assert(decayedBaseRate <= DECIMAL_PRECISION);  // The baseRate can decay to 0

        baseRate[_asset] = decayedBaseRate;
        emit BaseRateUpdated(_asset, decayedBaseRate);

        _updateLastFeeOpTime(_asset);
    }

    // --- Internal fee functions ---

    // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
    function _updateLastFeeOpTime(address _asset) internal {
        uint256 timePassed = block.timestamp.sub(lastFeeOperationTime[_asset]);

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastFeeOperationTime[_asset] = block.timestamp;
            emit LastFeeOpTimeUpdated(_asset, block.timestamp);
        }
    }

    function _calcDecayedBaseRate(address _asset) internal view returns (uint256) {
        uint256 minutesPassed = _minutesPassedSinceLastFeeOp(_asset);
        uint256 decayFactor = StablisMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

        return baseRate[_asset].mul(decayFactor).div(DECIMAL_PRECISION);
    }

    function _minutesPassedSinceLastFeeOp(address _asset) internal view returns (uint256) {
        return (block.timestamp.sub(lastFeeOperationTime[_asset])).div(SECONDS_IN_ONE_MINUTE);
    }

    // --- 'require' wrapper functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "Caller is not BO");
    }

    function _requireCallerIsBOorAttributes() internal view {
        require(msg.sender == borrowerOperationsAddress || msg.sender == address(attributes), "Caller is not BO or Attributes");
    }

    function _requireChestIsActive(address _asset, address _borrower) internal view {
        require(Chests[_asset][_borrower].status == Status.active, "Chest not active");
    }

    function _requireUSDSBalanceCoversRedemption(IUSDSToken _usdsToken, address _redeemer, uint256 _amount) internal view {
        require(_usdsToken.balanceOf(_redeemer) >= _amount, "Redemption amount must be <= user's USDS balance");
    }

    function _requireMoreThanOneChestInSystem(address _asset, uint256 ChestOwnersArrayLength) internal view {
        require (ChestOwnersArrayLength > 1 && sortedChests.getSize(_asset) > 1, "Only 1 chest in the system");
    }

    function _requireAmountGreaterThanZero(uint256 _amount) internal pure {
        require(_amount > 0, "Amount must be > 0");
    }

    function _requireTCRoverMCR(address _asset, uint256 _price) internal view {
        require(_getTCR(_asset, _price) >= getMCR(), "Cannot redeem when TCR < MCR");
    }

    function _requireAfterBootstrapPeriod() internal view {
        uint256 systemDeploymentTime = stablisToken.getDeploymentStartTime();
        require(block.timestamp >= systemDeploymentTime.add(BOOTSTRAP_PERIOD), "Redemptions are not allowed in bootstrap phase");
    }

    function _requireValidMaxFeePercentage(uint256 _maxFeePercentage) internal pure {
        require(_maxFeePercentage >= REDEMPTION_FEE_FLOOR && _maxFeePercentage <= DECIMAL_PRECISION,
            "Max fee % must be between 0.5% and 100%");
    }

    // --- Chest property getters ---

    function getChestStatus(address _asset, address _borrower) external view override returns (uint256) {
        return uint(Chests[_asset][_borrower].status);
    }

    function getChestStake(address _asset, address _borrower) external view override returns (uint256) {
        return Chests[_asset][_borrower].stake;
    }

    function getChestDebt(address _asset, address _borrower) external view override returns (uint256) {
        return Chests[_asset][_borrower].debt;
    }

    function getChestColl(address _asset, address _borrower) external view override returns (uint256) {
        return Chests[_asset][_borrower].coll;
    }

    // --- Chest property setters, called by BorrowerOperations ---

    function setChestStatus(address _asset, address _borrower, uint256 _num) external override {
        _requireCallerIsBorrowerOperations();
        Chests[_asset][_borrower].status = Status(_num);
    }

    function increaseChestColl(address _asset, address _borrower, uint256 _collIncrease) external override returns (uint256) {
        _requireCallerIsBorrowerOperations();
        uint256 newColl = Chests[_asset][_borrower].coll.add(_collIncrease);
        Chests[_asset][_borrower].coll = newColl;
        return newColl;
    }

    function decreaseChestColl(address _asset, address _borrower, uint256 _collDecrease) external override returns (uint256) {
        _requireCallerIsBorrowerOperations();
        uint256 newColl = Chests[_asset][_borrower].coll.sub(_collDecrease);
        Chests[_asset][_borrower].coll = newColl;
        return newColl;
    }

    function increaseChestDebt(address _asset, address _borrower, uint256 _debtIncrease) external override returns (uint256) {
        _requireCallerIsBorrowerOperations();
        uint256 newDebt = Chests[_asset][_borrower].debt.add(_debtIncrease);
        Chests[_asset][_borrower].debt = newDebt;
        usdsAirdrop.updateStake(_asset, _borrower, newDebt);
        return newDebt;
    }

    function decreaseChestDebt(address _asset, address _borrower, uint256 _debtDecrease) external override returns (uint256) {
        _requireCallerIsBorrowerOperations();
        uint256 newDebt = Chests[_asset][_borrower].debt.sub(_debtDecrease);
        Chests[_asset][_borrower].debt = newDebt;
        usdsAirdrop.updateStake(_asset, _borrower, newDebt);
        return newDebt;
    }

    function setChestInterestIndex(address _asset, address _borrower, uint256 _interestIndex) external override {
        _requireCallerIsBorrowerOperations();
        Chests[_asset][_borrower].activeInterestIndex = _interestIndex;
    }
}
