// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import './Interfaces/IBorrowerOperations.sol';
import './Interfaces/IStabilityPool.sol';
import './Interfaces/IBorrowerOperations.sol';
import './Interfaces/IChestManager.sol';
import './Interfaces/IUSDSToken.sol';
import './Interfaces/ISortedChests.sol';
import "./Interfaces/ICommunityIssuance.sol";
import "./Interfaces/IAttributes.sol";
import "./Dependencies/StablisBase.sol";
import "./Dependencies/StablisMath.sol";
import "./Dependencies/StablisSafeMath128.sol";
import "./Dependencies/CheckContract.sol";

/*
 * The Stability Pool holds USDS tokens deposited by Stability Pool depositors.
 *
 * When a chest is liquidated, then depending on system conditions, some of its USDS debt gets offset with
 * USDS in the Stability Pool:  that is, the offset debt evaporates, and an equal amount of USDS tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a USDS loss, in proportion to their deposit as a share of total deposits.
 * They also receive an ETH gain, as the ETH collateral of the liquidated chest is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total USDS in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 *
 * --- IMPLEMENTATION ---
 *
 * We use a highly scalable method of tracking deposits and ETH gains that has O(1) complexity.
 *
 * When a liquidation occurs, rather than updating each depositor's deposit and ETH gain, we simply update two state variables:
 * a product P, and a sum S.
 *
 * A mathematical manipulation allows us to factor out the initial deposit, and accurately track all depositors' compounded deposits
 * and accumulated ETH gains over time, as liquidations occur, using just these two variables P and S. When depositors join the
 * Stability Pool, they get a snapshot of the latest P and S: P_t and S_t, respectively.
 *
 * The formula for a depositor's accumulated ETH gain is derived here:
 * https://github.com/stablis/dev/blob/main/packages/contracts/mathProofs/Scalable%20Compounding%20Stability%20Pool%20Deposits.pdf
 *
 * For a given deposit d_t, the ratio P/P_t tells us the factor by which a deposit has decreased since it joined the Stability Pool,
 * and the term d_t * (S - S_t)/P_t gives us the deposit's total accumulated ETH gain.
 *
 * Each liquidation updates the product P and sum S. After a series of liquidations, a compounded deposit and corresponding ETH gain
 * can be calculated using the initial deposit, the depositor’s snapshots of P and S, and the latest values of P and S.
 *
 * Any time a depositor updates their deposit (withdrawal, top-up) their accumulated ETH gain is paid out, their new deposit is recorded
 * (based on their latest compounded deposit and modified by the withdrawal/top-up), and they receive new snapshots of the latest P and S.
 * Essentially, they make a fresh deposit that overwrites the old one.
 *
 *
 * --- SCALE FACTOR ---
 *
 * Since P is a running product in range ]0,1] that is always-decreasing, it should never reach 0 when multiplied by a number in range ]0,1[.
 * Unfortunately, Solidity floor division always reaches 0, sooner or later.
 *
 * A series of liquidations that nearly empty the Pool (and thus each multiply P by a very small number in range ]0,1[ ) may push P
 * to its 18 digit decimal limit, and round it to 0, when in fact the Pool hasn't been emptied: this would break deposit tracking.
 *
 * So, to track P accurately, we use a scale factor: if a liquidation would cause P to decrease to <1e-9 (and be rounded to 0 by Solidity),
 * we first multiply P by 1e9, and increment a currentScale factor by 1.
 *
 * The added benefit of using 1e9 for the scale factor (rather than 1e18) is that it ensures negligible precision loss close to the
 * scale boundary: when P is at its minimum value of 1e9, the relative precision loss in P due to floor division is only on the
 * order of 1e-9.
 *
 * --- EPOCHS ---
 *
 * Whenever a liquidation fully empties the Stability Pool, all deposits should become 0. However, setting P to 0 would make P be 0
 * forever, and break all future reward calculations.
 *
 * So, every time the Stability Pool is emptied by a liquidation, we reset P = 1 and currentScale = 0, and increment the currentEpoch by 1.
 *
 * --- TRACKING DEPOSIT OVER SCALE CHANGES AND EPOCHS ---
 *
 * When a deposit is made, it gets snapshots of the currentEpoch and the currentScale.
 *
 * When calculating a compounded deposit, we compare the current epoch to the deposit's epoch snapshot. If the current epoch is newer,
 * then the deposit was present during a pool-emptying liquidation, and necessarily has been depleted to 0.
 *
 * Otherwise, we then compare the current scale to the deposit's scale snapshot. If they're equal, the compounded deposit is given by d_t * P/P_t.
 * If it spans one scale change, it is given by d_t * P/(P_t * 1e9). If it spans more than one scale change, we define the compounded deposit
 * as 0, since it is now less than 1e-9'th of its initial value (e.g. a deposit of 1 billion USDS has depleted to < 1 USDS).
 *
 *
 *  --- TRACKING DEPOSITOR'S ETH GAIN OVER SCALE CHANGES AND EPOCHS ---
 *
 * In the current epoch, the latest value of S is stored upon each scale change, and the mapping (scale -> S) is stored for each epoch.
 *
 * This allows us to calculate a deposit's accumulated ETH gain, during the epoch in which the deposit was non-zero and earned ETH.
 *
 * We calculate the depositor's accumulated ETH gain for the scale at which they made the deposit, using the ETH gain formula:
 * e_1 = d_t * (S - S_t) / P_t
 *
 * and also for scale after, taking care to divide the latter by a factor of 1e9:
 * e_2 = d_t * S / (P_t * 1e9)
 *
 * The gain in the second scale will be full, as the starting point was in the previous scale, thus no need to subtract anything.
 * The deposit therefore was present for reward events from the beginning of that second scale.
 *
 *        S_i-S_t + S_{i+1}
 *      .<--------.------------>
 *      .         .
 *      . S_i     .   S_{i+1}
 *   <--.-------->.<----------->
 *   S_t.         .
 *   <->.         .
 *      t         .
 *  |---+---------|-------------|-----...
 *         i            i+1
 *
 * The sum of (e_1 + e_2) captures the depositor's total accumulated ETH gain, handling the case where their
 * deposit spanned one scale change. We only care about gains across one scale change, since the compounded
 * deposit is defined as being 0 once it has spanned more than one scale change.
 *
 *
 * --- UPDATING P WHEN A LIQUIDATION OCCURS ---
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/stablis/stablis/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 */
contract StabilityPool is StablisBase, OwnableUpgradeable, ReentrancyGuardUpgradeable, CheckContract, IStabilityPool {
    using SafeMathUpgradeable for uint256;
    using StablisSafeMath128 for uint128;

    string constant public NAME = "StabilityPool";
    address constant ETH_REF_ADDRESS = address(0);

    IBorrowerOperations public borrowerOperations;

    IChestManager public chestManager;

    IUSDSToken public usdsToken;

    // Needed to check if there are pending liquidations
    ISortedChests public sortedChests;

    ICommunityIssuance public communityIssuance;

    // Map from asset address to asset balance
    mapping(address => uint256) internal ETH;

    // Tracker for USDS held in the pool. Changes when users deposit/withdraw, and when Chest debt is offset.
    uint256 internal totalUSDSDeposits;

    // Tracker for reward tokens claimed by external wallets
    uint256 internal cachedRewardBalance;

    // --- Data structures ---

    struct Deposit {
        uint256 initialValue;
        address frontEndTag;
    }

    struct Snapshots {
        mapping(address => uint256) assetS; // Map from asset address to asset S
        uint256 P;
        uint256 G;
        uint128 scale;
        uint128 epoch;
    }

    mapping (address => Deposit) public deposits;  // depositor address -> Deposit struct
    mapping (address => Snapshots) public depositSnapshots;  // depositor address -> snapshots struct

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
    * after a series of liquidations have occurred, each of which cancel some USDS debt with the deposit.
    *
    * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
    * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
    */
    uint256 public P;

    uint256 public constant SCALE_FACTOR = 1e9;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    uint128 public currentScale;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    uint128 public currentEpoch;

    /* ETH Gain sum 'S': During its lifetime, each deposit d_t earns an ETH gain of ( d_t * [S - S_t] )/P_t, where S_t
    * is the depositor's snapshot of S taken at the time t when the deposit was made.
    *
    * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
    *
    * - The inner mapping records the sum S at different scales
    * - The outer mapping records the (scale => sum) mappings, for different epochs.
    */
    mapping (uint128 => mapping(uint128 => mapping(address => uint256))) public epochToScaleToAssetToSum;

    /*
    * Similarly, the sum 'G' is used to calculate Stablis gains. During it's lifetime, each deposit d_t earns a Stablis gain of
    *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
    *
    *  Stablis reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
    *  In each case, the Stablis reward is issued (i.e. G is updated), before other state changes are made.
    */
    mapping (uint128 => mapping(uint128 => uint256)) public epochToScaleToG;

    // Error tracker for the error correction in the Stablis issuance calculation
    uint256 public lastStablisError;
    // Error trackers for the error correction in the offset calculation
    mapping (address => uint256) public lastETHError_Offset; // Mapping from asset address to last asset error
    uint256 public lastUSDSLossError_Offset;

    // --- Contract setters ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        override
        initializer
    {
        __ReentrancyGuard_init();
        __Ownable_init();

        P = DECIMAL_PRECISION;

        checkContract(_dependencies.activePool);
        checkContract(_dependencies.attributes);
        checkContract(_dependencies.borrowerOperations);
        checkContract(_dependencies.chestManager);
        checkContract(_dependencies.communityIssuance);
        checkContract(_dependencies.priceFeed);
        checkContract(_dependencies.sortedChests);
        checkContract(_dependencies.usdsToken);

        activePool = IActivePool(_dependencies.activePool);
        attributes = IAttributes(_dependencies.attributes);
        borrowerOperations = IBorrowerOperations(_dependencies.borrowerOperations);
        chestManager = IChestManager(_dependencies.chestManager);
        communityIssuance = ICommunityIssuance(_dependencies.communityIssuance);
        priceFeed = IPriceFeed(_dependencies.priceFeed);
        sortedChests = ISortedChests(_dependencies.sortedChests);
        usdsToken = IUSDSToken(_dependencies.usdsToken);

        _transferOwnership(_multiSig);
    }

    // --- Getters for public variables. Required by IPool interface ---

    function getETH(address _asset) external view override returns (uint256) {
        return ETH[_asset];
    }

    function getTotalUSDSDeposits() external view override returns (uint256) {
        return totalUSDSDeposits;
    }

    function getAssetS(address depositor, address _asset) public view returns (uint256) {
        return depositSnapshots[depositor].assetS[_asset];
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
    *
    * - Triggers a Stablis issuance, based on time passed since the last issuance. The Stablis issuance is shared between *all* depositors
    * - Sends depositor's accumulated collateral gains to depositor
    * - Increases deposit and takes new snapshots for each.
    */
    function provideToSP(uint256 _amount) external override nonReentrant {
        _requireNonZeroAmount(_amount);
        _requireNotPaused();

        uint256 initialDeposit = deposits[msg.sender].initialValue;

        ICommunityIssuance communityIssuanceCached = communityIssuance;
        _triggerStablisIssuance(communityIssuanceCached);

        uint256 compoundedUSDSDeposit = getCompoundedUSDSDeposit(msg.sender);
        uint256 USDSLoss = initialDeposit.sub(compoundedUSDSDeposit); // Needed only for event log

        // First pay out any Stablis gains
        _payOutStablisGains(communityIssuanceCached, msg.sender);

        // Pay out collateral gains
        address[] memory assets = attributes.getAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 depositorAssetGain = getDepositorETHGain(asset, msg.sender);
            _sendETHGainToDepositor(asset, depositorAssetGain);
            emit ETHGainWithdrawn(asset, msg.sender, depositorAssetGain, USDSLoss); // USDS Loss required for event log
        }

        _sendUSDStoStabilityPool(msg.sender, _amount);

        uint256 newDeposit = compoundedUSDSDeposit.add(_amount);
        _updateDepositAndSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);
    }

    /*  withdrawFromSP():
    *
    * - Triggers a Stablis issuance, based on time passed since the last issuance. The Stablis issuance is shared between *all* depositors
    * - Sends all depositor's accumulated collateral gains to depositor
    * - Decreases deposit and takes a new snapshot.
    *
    * If _amount > userDeposit, the user withdraws all of their compounded deposit.
    */
    function withdrawFromSP(uint256 _amount) external override nonReentrant {
        if (_amount !=0) {_requireNoUnderCollateralizedChests();}
        uint256 initialDeposit = deposits[msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);

        ICommunityIssuance communityIssuanceCached = communityIssuance;
        _triggerStablisIssuance(communityIssuanceCached);

        uint256 compoundedUSDSDeposit = getCompoundedUSDSDeposit(msg.sender);
        uint256 USDStoWithdraw = StablisMath._min(_amount, compoundedUSDSDeposit);
        uint256 USDSLoss = initialDeposit.sub(compoundedUSDSDeposit); // Needed only for event log

        // First pay out any Stablis gains
        _payOutStablisGains(communityIssuanceCached, msg.sender);

        // Pay out collateral gains
        address[] memory assets = attributes.getAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 depositorAssetGain = getDepositorETHGain(asset, msg.sender);
            _sendETHGainToDepositor(asset, depositorAssetGain);
            emit ETHGainWithdrawn(asset, msg.sender, depositorAssetGain, USDSLoss); // USDS Loss required for event log
        }

        _sendUSDSToDepositor(msg.sender, USDStoWithdraw);

        // Update deposit
        uint256 newDeposit = compoundedUSDSDeposit.sub(USDStoWithdraw);
        _updateDepositAndSnapshots(msg.sender, newDeposit);
        emit UserDepositChanged(msg.sender, newDeposit);
    }

    /* withdrawETHGainToChest:
    * - Triggers a Stablis issuance, based on time passed since the last issuance. The Stablis issuance is shared between *all* depositors
    * - Transfers the depositor's entire ETH gain from the Stability Pool to the caller's chest
    * - Leaves their compounded deposit in the Stability Pool
    * - Updates snapshot for deposit
    */
    function withdrawETHGainToChest(address _asset, address _upperHint, address _lowerHint) external override nonReentrant {
        uint256 initialDeposit = deposits[msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);
        _requireUserHasChest(_asset, msg.sender);
        _requireUserHasETHGain(_asset, msg.sender);

        ICommunityIssuance communityIssuanceCached = communityIssuance;
        _triggerStablisIssuance(communityIssuanceCached);

        uint256 compoundedUSDSDeposit = getCompoundedUSDSDeposit(msg.sender);
        uint256 USDSLoss = initialDeposit.sub(compoundedUSDSDeposit); // Needed only for event log

        // First pay out any Stablis gains
        _payOutStablisGains(communityIssuanceCached, msg.sender);

        // Compound into chest and pay out other collateral gains
        address[] memory assets = attributes.getAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 depositorAssetGain = getDepositorETHGain(asset, msg.sender);
            if (asset == _asset) {
                /* Emit events before transferring ETH gain to Chest.
                *  This lets the event log make more sense (i.e. so it appears that first the ETH gain is withdrawn
                *  and then it is deposited into the Chest, not the other way around).
                */
                emit ETHGainWithdrawn(_asset, msg.sender, depositorAssetGain, USDSLoss);
                emit UserDepositChanged(msg.sender, compoundedUSDSDeposit);
                _sendETHGainToChest(asset, depositorAssetGain, _upperHint, _lowerHint);
            } else {
                _sendETHGainToDepositor(asset, depositorAssetGain);
                emit ETHGainWithdrawn(asset, msg.sender, depositorAssetGain, USDSLoss);
            }
        }

        _updateDepositAndSnapshots(msg.sender, compoundedUSDSDeposit);
    }

    // --- Stablis issuance functions ---

    function _triggerStablisIssuance(ICommunityIssuance _communityIssuance) internal {
        uint256 stablisIssuance = _communityIssuance.issueStablisSP();
        _updateG(stablisIssuance);
    }

    function _updateG(uint256 _stablisIssuance) internal {
        uint256 totalUSDS = totalUSDSDeposits; // cached to save an SLOAD
        /*
        * When total deposits is 0, G is not updated. In this case, the Stablis issued can not be obtained by later
        * depositors - it is missed out on, and remains in the balanceof the CommunityIssuance contract.
        *
        */
        if (totalUSDS == 0 || _stablisIssuance == 0) {return;}

        uint256 stablisPerUnitStaked;
        stablisPerUnitStaked =_computeStablisPerUnitStaked(_stablisIssuance, totalUSDS);

        uint256 marginalStablisGain = stablisPerUnitStaked.mul(P);
        epochToScaleToG[currentEpoch][currentScale] = epochToScaleToG[currentEpoch][currentScale].add(marginalStablisGain);

        emit G_Updated(epochToScaleToG[currentEpoch][currentScale], currentEpoch, currentScale);
    }

    function _computeStablisPerUnitStaked(uint256 _stablisIssuance, uint256 _totalUSDSDeposits) internal returns (uint256) {
        /*
        * Calculate the stablis-per-unit staked.  Division uses a "feedback" error correction, to keep the
        * cumulative error low in the running total G:
        *
        * 1) Form a numerator which compensates for the floor division error that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratio.
        * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
        * 4) Store this error for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint256 stablisNumerator = _stablisIssuance.mul(DECIMAL_PRECISION).add(lastStablisError);

        uint256 stablisPerUnitStaked = stablisNumerator.div(_totalUSDSDeposits);
        lastStablisError = stablisNumerator.sub(stablisPerUnitStaked.mul(_totalUSDSDeposits));

        return stablisPerUnitStaked;
    }

    // --- Liquidation functions ---

    /*
    * Cancels out the specified debt against the USDS contained in the Stability Pool (as far as possible)
    * and transfers the Chest's ETH collateral from ActivePool to StabilityPool.
    * Only called by liquidation functions in the ChestManager.
    */
    function offset(address _asset, uint256 _debtToOffset, uint256 _collToAdd) external override {
        _requireCallerIsChestManager();
        uint256 totalUSDS = totalUSDSDeposits; // cached to save an SLOAD
        if (totalUSDS == 0 || _debtToOffset == 0) { return; }

        _triggerStablisIssuance(communityIssuance);

        (uint256 ETHGainPerUnitStaked,
            uint256 USDSLossPerUnitStaked) = _computeRewardsPerUnitStaked(_asset, _collToAdd, _debtToOffset, totalUSDS);

        _updateRewardSumAndProduct(_asset, ETHGainPerUnitStaked, USDSLossPerUnitStaked);  // updates S and P

        _moveOffsetCollAndDebt(_asset, _collToAdd, _debtToOffset);
    }

    // --- Offset helper functions ---

    function _computeRewardsPerUnitStaked(
        address _asset,
        uint256 _collToAdd,
        uint256 _debtToOffset,
        uint256 _totalUSDSDeposits
    )
        internal
        returns (uint256 ETHGainPerUnitStaked, uint256 USDSLossPerUnitStaked)
    {
        /*
        * Compute the USDS and ETH rewards. Uses a "feedback" error correction, to keep
        * the cumulative error in the P and S state variables low:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint256 ETHNumerator = _collToAdd.mul(DECIMAL_PRECISION).add(lastETHError_Offset[_asset]);

        assert(_debtToOffset <= _totalUSDSDeposits);
        if (_debtToOffset == _totalUSDSDeposits) {
            USDSLossPerUnitStaked = DECIMAL_PRECISION;  // When the Pool depletes to 0, so does each deposit
            lastUSDSLossError_Offset = 0;
        } else {
            uint256 USDSLossNumerator = _debtToOffset.mul(DECIMAL_PRECISION).sub(lastUSDSLossError_Offset);
            /*
            * Add 1 to make error in quotient positive. We want "slightly too much" USDS loss,
            * which ensures the error in any given compoundedUSDSDeposit favors the Stability Pool.
            */
            USDSLossPerUnitStaked = (USDSLossNumerator.div(_totalUSDSDeposits)).add(1);
            lastUSDSLossError_Offset = (USDSLossPerUnitStaked.mul(_totalUSDSDeposits)).sub(USDSLossNumerator);
        }

        ETHGainPerUnitStaked = ETHNumerator.div(_totalUSDSDeposits);
        lastETHError_Offset[_asset] = ETHNumerator.sub(ETHGainPerUnitStaked.mul(_totalUSDSDeposits));

        return (ETHGainPerUnitStaked, USDSLossPerUnitStaked);
    }

    // Update the Stability Pool reward sum S and product P
    function _updateRewardSumAndProduct(address _asset, uint256 _ETHGainPerUnitStaked, uint256 _USDSLossPerUnitStaked) internal {
        uint256 currentP = P;
        uint256 newP;

        assert(_USDSLossPerUnitStaked <= DECIMAL_PRECISION);
        /*
        * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool USDS in the liquidation.
        * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - USDSLossPerUnitStaked)
        */
        uint256 newProductFactor = uint(DECIMAL_PRECISION).sub(_USDSLossPerUnitStaked);

        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentS = epochToScaleToAssetToSum[currentEpochCached][currentScaleCached][_asset];

        /*
        * Calculate the new S first, before we update P.
        * The ETH gain for any given depositor from a liquidation depends on the value of their deposit
        * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
        *
        * Since S corresponds to ETH gain, and P to deposit loss, we update S first.
        */
        uint256 marginalETHGain = _ETHGainPerUnitStaked.mul(currentP);
        uint256 newS = currentS.add(marginalETHGain);

        epochToScaleToAssetToSum[currentEpochCached][currentScaleCached][_asset] = newS;

        emit S_Updated(_asset, newS, currentEpochCached, currentScaleCached);

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            currentEpoch = currentEpochCached.add(1);
            emit EpochUpdated(currentEpoch);
            currentScale = 0;
            emit ScaleUpdated(currentScale);
            newP = DECIMAL_PRECISION;

        // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else if (currentP.mul(newProductFactor).div(DECIMAL_PRECISION) < SCALE_FACTOR) {
            newP = currentP.mul(newProductFactor).mul(SCALE_FACTOR).div(DECIMAL_PRECISION);
            currentScale = currentScaleCached.add(1);
            emit ScaleUpdated(currentScale);
        } else {
            newP = currentP.mul(newProductFactor).div(DECIMAL_PRECISION);
        }

        assert(newP > 0);
        P = newP;

        emit P_Updated(newP);
    }

    function _moveOffsetCollAndDebt(address _asset, uint256 _collToAdd, uint256 _debtToOffset) internal {
        IActivePool activePoolCached = activePool;

        // Cancel the liquidated USDS debt with the USDS in the stability pool
        activePoolCached.decreaseUSDSDebt(_asset, _debtToOffset);
        _decreaseUSDS(_debtToOffset);

        // Burn the debt that was successfully offset
        usdsToken.burn(address(this), _debtToOffset);

        activePoolCached.sendETH(_asset, address(this), _collToAdd);
    }

    function _decreaseUSDS(uint256 _amount) internal {
        uint256 newTotalUSDSDeposits = totalUSDSDeposits.sub(_amount);
        totalUSDSDeposits = newTotalUSDSDeposits;
        emit StabilityPoolUSDSBalanceUpdated(newTotalUSDSDeposits);
    }

    // --- Reward calculator functions for depositor ---

    /* Calculates the ETH gain earned by the deposit since its last snapshots were taken.
    * Given by the formula:  E = d0 * (S - S(0))/P(0)
    * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorETHGain(address _asset, address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) { return 0; }

        uint256 ETHGain = _getETHGainFromSnapshots(_asset, initialDeposit, _depositor);
        return ETHGain;
    }

    function _getETHGainFromSnapshots(address _asset, uint256 initialDeposit, address _depositor) internal view returns (uint256) {
        /*
        * Grab the sum 'S' from the epoch at which the stake was made. The ETH gain may span up to one scale change.
        * If it does, the second portion of the ETH gain is scaled by 1e9.
        * If the gain spans no scale change, the second portion will be 0.
        */
        Snapshots storage snapshots = depositSnapshots[_depositor];

        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;

        uint256 firstPortion = epochToScaleToAssetToSum[epochSnapshot][scaleSnapshot][_asset].sub(snapshots.assetS[_asset]);
        uint256 secondPortion = epochToScaleToAssetToSum[epochSnapshot][scaleSnapshot.add(1)][_asset].div(SCALE_FACTOR);

        uint256 ETHGain = initialDeposit.mul(firstPortion.add(secondPortion)).div(snapshots.P).div(DECIMAL_PRECISION);

        return ETHGain;
    }

    /*
    * Calculate the Stablis gain earned by a deposit since its last snapshots were taken.
    * Given by the formula:  Stablis = d0 * (G - G(0))/P(0)
    * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorStablisGain(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) {return 0;}

        Snapshots storage snapshots = depositSnapshots[_depositor];

        uint256 stablisGain = _getStablisGainFromSnapshots(initialDeposit, snapshots);
        return stablisGain;
    }

    function _getStablisGainFromSnapshots(uint256 initialStake, Snapshots storage snapshots) internal view returns (uint256) {
        /*
         * Grab the sum 'G' from the epoch at which the stake was made. The Stablis gain may span up to one scale change.
         * If it does, the second portion of the Stablis gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;
        uint256 G_Snapshot = snapshots.G;
        uint256 P_Snapshot = snapshots.P;

        uint256 firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot].sub(G_Snapshot);
        uint256 secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot.add(1)].div(SCALE_FACTOR);

        uint256 stablisGain = initialStake.mul(firstPortion.add(secondPortion)).div(P_Snapshot).div(DECIMAL_PRECISION);

        return stablisGain;
    }

    // --- Compounded deposit and compounded front end stake ---

    /*
    * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
    * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
    */
    function getCompoundedUSDSDeposit(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) { return 0; }

        Snapshots storage snapshots = depositSnapshots[_depositor];

        uint256 compoundedDeposit = _getCompoundedStakeFromSnapshots(initialDeposit, snapshots);
        return compoundedDeposit;
    }

    // Internal function, used to calculate compounded deposits
    function _getCompoundedStakeFromSnapshots(
        uint256 initialStake,
        Snapshots storage snapshots
    )
        internal
        view
        returns (uint256)
    {
        uint256 snapshot_P = snapshots.P;
        uint128 scaleSnapshot = snapshots.scale;
        uint128 epochSnapshot = snapshots.epoch;

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (epochSnapshot < currentEpoch) { return 0; }

        uint256 compoundedStake;
        uint128 scaleDiff = currentScale.sub(scaleSnapshot);

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
        * account for it. If more than one scale change was made, then the stake has decreased by a factor of
        * at least 1e-9 -- so return 0.
        */
        if (scaleDiff == 0) {
            compoundedStake = initialStake.mul(P).div(snapshot_P);
        } else if (scaleDiff == 1) {
            compoundedStake = initialStake.mul(P).div(snapshot_P).div(SCALE_FACTOR);
        } else { // if scaleDiff >= 2
            compoundedStake = 0;
        }

        /*
        * If compounded deposit is less than a billionth of the initial deposit, return 0.
        *
        * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
        * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
        * than it's theoretical value.
        *
        * Thus it's unclear whether this line is still really needed.
        */
        if (compoundedStake < initialStake.div(1e9)) {return 0;}
        return compoundedStake;
    }

    // --- Sender functions for USDS deposit and collateral gains---

    // Transfer the USDS tokens from the user to the Stability Pool's address, and update its recorded USDS
    function _sendUSDStoStabilityPool(address _address, uint256 _amount) internal {
        usdsToken.sendToPool(_address, address(this), _amount);
        uint256 newTotalUSDSDeposits = totalUSDSDeposits.add(_amount);
        totalUSDSDeposits = newTotalUSDSDeposits;
        emit StabilityPoolUSDSBalanceUpdated(newTotalUSDSDeposits);
    }

    function _sendETHGainToDepositor(address _asset, uint256 _amount) internal {
        if (_amount == 0) {return;}
        uint256 newETH = ETH[_asset].sub(_amount);
        ETH[_asset] = newETH;
        emit StabilityPoolETHBalanceUpdated(_asset, newETH);
        emit EtherSent(_asset, msg.sender, _amount);

        if (_asset == ETH_REF_ADDRESS) {
            (bool success, ) = msg.sender.call{ value: _amount }("");
            require(success, "StabilityPool: sending ETH failed");
        } else {
            SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(_asset), msg.sender, StablisMath.decimalsCorrection(_asset, _amount));
        }
    }

    function _sendETHGainToChest(address _asset, uint256 _depositorAssetGain, address _upperHint, address _lowerHint) internal {
        ETH[_asset] = ETH[_asset].sub(_depositorAssetGain);
        emit StabilityPoolETHBalanceUpdated(_asset, ETH[_asset]);
        emit EtherSent(_asset, msg.sender, _depositorAssetGain);

        borrowerOperations.moveETHGainToChest{
                value: _asset == ETH_REF_ADDRESS ? _depositorAssetGain : 0
            }(_asset, _depositorAssetGain, msg.sender, _upperHint, _lowerHint);
    }

    // Send USDS to user and decrease USDS in Pool
    function _sendUSDSToDepositor(address _depositor, uint256 USDSWithdrawal) internal {
        if (USDSWithdrawal == 0) {return;}

        usdsToken.returnFromPool(address(this), _depositor, USDSWithdrawal);
        _decreaseUSDS(USDSWithdrawal);
    }

    // --- Stability Pool Deposit Functionality ---

    function _updateDepositAndSnapshots(address _depositor, uint256 _newValue) internal {
        deposits[_depositor].initialValue = _newValue;

        address[] memory assets = attributes.getAssets();
        if (_newValue == 0) {
            // Set the running sum of every known collateral type to 0, this is necessary because deleting a mapping is not possible.
            for (uint256 i = 0; i < assets.length; i++) {
                address asset = assets[i];
                depositSnapshots[_depositor].assetS[asset] = 0;
            }
            delete depositSnapshots[_depositor];
            emit DepositSnapshotUpdated(_depositor, 0, 0, 0);
            return;
        }
        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentP = P;

        // Get S and G for the current epoch and current scale
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 currentS = epochToScaleToAssetToSum[currentEpochCached][currentScaleCached][asset];
            depositSnapshots[_depositor].assetS[asset] = currentS;
        }
        uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];

        // Record new snapshots of the latest running product P and sum S for the depositor
        depositSnapshots[_depositor].P = currentP;
        depositSnapshots[_depositor].G = currentG;
        depositSnapshots[_depositor].scale = currentScaleCached;
        depositSnapshots[_depositor].epoch = currentEpochCached;

        emit DepositSnapshotUpdated(_depositor, currentP, 0, currentG);
    }

    function _payOutStablisGains(ICommunityIssuance _communityIssuance, address _depositor) internal {
        // Pay out depositor's Stablis gain
        uint256 depositorStablisGain = getDepositorStablisGain(_depositor);
        _communityIssuance.sendStablis(_depositor, depositorStablisGain);
        emit StablisPaidToDepositor(_depositor, depositorStablisGain);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require( msg.sender == address(activePool), "StabilityPool: Caller is not ActivePool");
    }

    function _requireCallerIsChestManager() internal view {
        require(msg.sender == address(chestManager), "StabilityPool: Caller is not ChestManager");
    }

    function _requireNoUnderCollateralizedChests() internal {
        uint256 MCR = getMCR();
        address[] memory assets = attributes.getAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 price = priceFeed.fetchPrice(asset);

            address lowestChest = sortedChests.getLast(asset);
            uint256 ICR = chestManager.getCurrentICR(asset, lowestChest, price);
            require(ICR >= MCR, "StabilityPool: Cannot withdraw while there are chests with ICR < MCR");
        }
    }

    function _requireUserHasDeposit(uint256 _initialDeposit) internal pure {
        require(_initialDeposit > 0, 'StabilityPool: User must have a non-zero deposit');
    }

    function _requireNonZeroAmount(uint256 _amount) internal pure {
        require(_amount > 0, 'StabilityPool: Amount must be non-zero');
    }

    function _requireUserHasChest(address _asset, address _depositor) internal view {
        require(chestManager.getChestStatus(_asset, _depositor) == 1, "StabilityPool: caller must have an active chest to withdraw ETHGain to");
    }

    function _requireUserHasETHGain(address _asset, address _depositor) internal view {
        uint256 ETHGain = getDepositorETHGain(_asset, _depositor);
        require(ETHGain > 0, "StabilityPool: caller must have non-zero ETH Gain");
    }

    function _requireNotPaused() internal view {
        require(!attributes.paused(), "StabilityPool: Protocol is paused");
    }

    // --- Fallback function ---

    function receivedERC20(address _asset, uint256 _amount) external override {
        _requireCallerIsActivePool();

        ETH[_asset] = ETH[_asset].add(_amount);
        emit StabilityPoolETHBalanceUpdated(_asset, ETH[_asset]);
    }

    receive() external payable {
        _requireCallerIsActivePool();
        ETH[ETH_REF_ADDRESS] = ETH[ETH_REF_ADDRESS].add(msg.value);
        emit StabilityPoolETHBalanceUpdated(ETH_REF_ADDRESS, ETH[ETH_REF_ADDRESS]);
    }
}
