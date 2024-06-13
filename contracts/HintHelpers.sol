// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";

import "./Interfaces/IChestManager.sol";
import "./Interfaces/ISortedChests.sol";
import "./Dependencies/StablisBase.sol";
import "./Dependencies/CheckContract.sol";

contract HintHelpers is StablisBase, CheckContract {
    using SafeMathUpgradeable for uint256;
    string constant public NAME = "HintHelpers";

    struct LocalRedemptionVars {
        address _asset;
        uint256 _VSTamount;
        uint256 _pricel;
        uint256 _maxIterations;
    }

    struct Dependencies {
        address attributes;
        address chestManager;
        address sortedChests;
    }

    ISortedChests public sortedChests;
    IChestManager public chestManager;

    // --- Dependency setters ---

    constructor(Dependencies memory _dependencies)
    {
        checkContract(_dependencies.attributes);
        checkContract(_dependencies.chestManager);
        checkContract(_dependencies.sortedChests);

        attributes = IAttributes(_dependencies.attributes);
        chestManager = IChestManager(_dependencies.chestManager);
        sortedChests = ISortedChests(_dependencies.sortedChests);
    }

    // --- Functions ---

    /* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
     *
     * It simulates a redemption of `_USDSamount` to figure out where the redemption sequence will start and what state the final Chest
     * of the sequence will end up in.
     *
     * Returns three hints:
     *  - `firstRedemptionHint` is the address of the first Chest with ICR >= MCR (i.e. the first Chest that will be redeemed).
     *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Chest of the sequence after being hit by partial redemption,
     *     or zero in case of no partial redemption.
     *  - `truncatedUSDSamount` is the maximum amount that can be redeemed out of the the provided `_USDSamount`. This can be lower than
     *    `_USDSamount` when redeeming the full amount would leave the last Chest of the redemption sequence with less net debt than the
     *    minimum allowed value (i.e. MIN_NET_DEBT).
     *
     * The number of Chests to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
     * will leave it uncapped.
     */

    function getRedemptionHints(
        address _asset,
        uint256 _USDSamount,
        uint256 _price,
        uint256 _maxIterations
    )
        external
        view
        returns (
            address firstRedemptionHint,
            uint256 partialRedemptionHintNICR,
            uint256 truncatedUSDSamount
        )
    {
        ISortedChests sortedChestsCached = sortedChests;
        LocalRedemptionVars memory vars = LocalRedemptionVars(
            _asset,
            _USDSamount,
            _price,
            _maxIterations
        );

        uint256 remainingUSDS = _USDSamount;
        address currentChestuser = sortedChestsCached.getLast(vars._asset);

        while (currentChestuser != address(0) && chestManager.getCurrentICR(vars._asset, currentChestuser, _price) < getMCR()) {
            currentChestuser = sortedChestsCached.getPrev(vars._asset, currentChestuser);
        }

        firstRedemptionHint = currentChestuser;

        if (_maxIterations == 0) {
            _maxIterations = type(uint256).max;
        }

        while (currentChestuser != address(0) && remainingUSDS > 0 && _maxIterations-- > 0) {
            (uint256 debt, uint256 coll, , ) = chestManager.getEntireDebtAndColl(_asset, currentChestuser);
            uint256 netUSDSDebt = _getNetDebt(debt);

            if (netUSDSDebt > remainingUSDS) {
                if (netUSDSDebt > getMinNetDebt()) {
                    uint256 maxRedeemableUSDS = StablisMath._min(remainingUSDS, netUSDSDebt.sub(getMinNetDebt()));

                    uint256 newColl = coll.sub(maxRedeemableUSDS.mul(DECIMAL_PRECISION).div(_price));
                    uint256 newDebt = netUSDSDebt.sub(maxRedeemableUSDS);

                    uint256 compositeDebt = _getCompositeDebt(newDebt);
                    partialRedemptionHintNICR = StablisMath._computeNominalCR(newColl, compositeDebt);

                    remainingUSDS = remainingUSDS.sub(maxRedeemableUSDS);
                }
                break;
            } else {
                remainingUSDS = remainingUSDS.sub(netUSDSDebt);
            }

            currentChestuser = sortedChestsCached.getPrev(vars._asset, currentChestuser);
        }

        truncatedUSDSamount = _USDSamount.sub(remainingUSDS);
    }

    /* getApproxHint() - return address of a Chest that is, on average, (length / numTrials) positions away in the
    sortedChests list from the correct insert position of the Chest to be inserted.

    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(address _asset, uint256 _CR, uint256 _numTrials, uint256 _inputRandomSeed)
        external
        view
        returns (address hintAddress, uint256 diff, uint256 latestRandomSeed)
    {
        uint256 arrayLength = chestManager.getChestOwnersCount(_asset);

        if (arrayLength == 0) {
            return (address(0), 0, _inputRandomSeed);
        }

        hintAddress = sortedChests.getLast(_asset);
        diff = StablisMath._getAbsoluteDifference(_CR, chestManager.getNominalICR(_asset, hintAddress));
        latestRandomSeed = _inputRandomSeed;

        uint256 i = 1;

        while (i < _numTrials) {
            latestRandomSeed = uint(keccak256(abi.encodePacked(latestRandomSeed)));

            uint256 arrayIndex = latestRandomSeed % arrayLength;
            address currentAddress = chestManager.getChestFromChestOwnersArray(_asset, arrayIndex);
            uint256 currentNICR = chestManager.getNominalICR(_asset, currentAddress);

            // check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint256 currentDiff = StablisMath._getAbsoluteDifference(currentNICR, _CR);

            if (currentDiff < diff) {
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    }

    function computeNominalCR(uint256 _coll, uint256 _debt) external pure returns (uint256) {
        return StablisMath._computeNominalCR(_coll, _debt);
    }

    function computeCR(uint256 _coll, uint256 _debt, uint256 _price) external pure returns (uint256) {
        return StablisMath._computeCR(_coll, _debt, _price);
    }
}
