// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IDeposit.sol";

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
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/stablis/stablis/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 */
interface IStabilityPool is IDeposit{
    struct Dependencies {
        address activePool;
        address attributes;
        address borrowerOperations;
        address chestManager;
        address communityIssuance;
        address priceFeed;
        address sortedChests;
        address usdsToken;
    }

    // --- Events ---

    event StabilityPoolETHBalanceUpdated(address indexed _asset, uint256 _newBalance);
    event StabilityPoolUSDSBalanceUpdated(uint256 _newBalance);

    event P_Updated(uint256 _P);
    event S_Updated(address indexed _asset, uint256 _S, uint128 _epoch, uint128 _scale);
    event G_Updated(uint256 _G, uint128 _epoch, uint128 _scale);
    event EpochUpdated(uint128 _currentEpoch);
    event ScaleUpdated(uint128 _currentScale);

    event DepositSnapshotUpdated(address indexed _depositor, uint256 _P, uint256 _S, uint256 _G);
    event UserDepositChanged(address indexed _depositor, uint256 _newDeposit);

    event ETHGainWithdrawn(address indexed _asset, address indexed _depositor, uint256 _ETH, uint256 _USDSLoss);
    event StablisPaidToDepositor(address indexed _depositor, uint256 _stablisGain);
    event EtherSent(address indexed _asset, address _to, uint256 _amount);

    // --- Functions ---

    /*
     * Called only once on init, to set addresses of other stablis contracts
     */
    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    ) external;

    /*
     * Initial checks:
     * - _amount is not zero
     * ---
     * - Sends depositor's accumulated collateral gains to depositor
     * - Increases deposit and takes new snapshots for each.
     */
    function provideToSP(uint256 _amount) external;

    /*
     * Initial checks:
     * - _amount is zero or there are no under collateralized chests left in the system
     * - User has a non zero deposit
     * ---
     * - Sends all depositor's accumulated gains (ETH) to depositor
     * - Decreases deposit stake, and takes new snapshot.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(uint256 _amount) external;

    /*
     * Initial checks:
     * - User has a non zero deposit
     * - User has an open chest
     * - User has some ETH gain
     * ---
     * - Transfers the depositor's entire ETH gain from the Stability Pool to the caller's chest
     * - Leaves their compounded deposit in the Stability Pool
     * - Updates snapshot for deposit
     */
    function withdrawETHGainToChest(address _asset, address _upperHint, address _lowerHint) external;

    /*
     * Initial checks:
     * - Caller is ChestManager
     * ---
     * Cancels out the specified debt against the USDS contained in the Stability Pool (as far as possible)
     * and transfers the Chest's ETH collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the ChestManager.
     */
    function offset(address _asset, uint256 _debt, uint256 _coll) external;

    /*
     * Returns the total amount of ETH held by the pool, accounted in an internal variable instead of `balance`,
     * to exclude edge cases like ETH received from a self-destruct.
     */
    function getETH(address _asset) external view returns (uint256);

    /*
     * Returns USDS held in the pool. Changes when users deposit/withdraw, and when Chest debt is offset.
     */
    function getTotalUSDSDeposits() external view returns (uint256);

    /*
     * Returns the last snapshot value of the running sum of an asset held in the pool for a specific depositor.
     */
    function getAssetS(address depositor, address _asset) external view returns (uint256);

    /*
     * Calculates the ETH gain earned by the deposit since its last snapshots were taken.
     */
    function getDepositorETHGain(address _asset, address _depositor) external view returns (uint256);

    /*
     * Calculates the Stablis gain earned by the deposit since its last snapshots were taken.
     */
    function getDepositorStablisGain(address _depositor) external view returns (uint256);

    /*
     * Return the user's compounded deposit.
     */
    function getCompoundedUSDSDeposit(address _depositor) external view returns (uint256);

    /*
     * Fallback function
     * Only callable by Active Pool, it just accounts for ETH received
     * receive() external payable;
     */
}
