// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./BaseMath.sol";
import "./StablisMath.sol";
import "../Interfaces/IActivePool.sol";
import "../Interfaces/IDefaultPool.sol";
import "../Interfaces/IPriceFeed.sol";
import "../Interfaces/IStablisBase.sol";
import "../Interfaces/IAttributes.sol";

/*
* Base contract for ChestManager, BorrowerOperations and StabilityPool. Contains global system constants and
* common functions.
*/
contract StablisBase is BaseMath, IStablisBase {
    using SafeMathUpgradeable for uint256;

    uint256 constant public _100pct = 1000000000000000000; // 1e18 == 100%

    IActivePool public activePool;

    IDefaultPool public defaultPool;

    IPriceFeed public override priceFeed;

    IAttributes public attributes;

    function getMCR() public view returns (uint256) {
        return attributes.getMCR();
    }

    function getUSDSGasCompensation() public view returns (uint256) {
        return attributes.getUSDSGasCompensation();
    }

    function getMinNetDebt() public view returns (uint256) {
        return attributes.getMinNetDebt();
    }

    function getBorrowingFeeFloor() public view returns (uint256) {
        return attributes.getBorrowingFeeFloor();
    }

    // --- Gas compensation functions ---

    // Returns the composite debt (drawn debt + gas compensation) of a chest, for the purpose of ICR calculation
    function _getCompositeDebt(uint256 _debt) internal view returns (uint256) {
        return _debt.add(getUSDSGasCompensation());
    }

    function _getNetDebt(uint256 _debt) internal view returns (uint256) {
        return _debt.sub(getUSDSGasCompensation());
    }

    // Return the amount of ETH to be drawn from a chest's collateral and sent as gas compensation.
    function _getCollGasCompensation(uint256 _entireColl) internal view returns (uint256) {
        return _entireColl.div(attributes.getColGasCompensationPercentDivisor());
    }

    function getEntireSystemColl(address _asset) public view returns (uint256 entireSystemColl) {
        uint256 activeColl = activePool.getETH(_asset);
        uint256 liquidatedColl = defaultPool.getETH(_asset);

        return activeColl.add(liquidatedColl);
    }

    function getEntireSystemDebt(address _asset) public view returns (uint256 entireSystemDebt) {
        uint256 activeDebt = activePool.getUSDSDebt(_asset);
        uint256 closedDebt = defaultPool.getUSDSDebt(_asset);

        (, uint256 interestFactor) = _calculateInterestIndex(_asset);
        if (interestFactor > 0) {
            uint256 activeInterests = StablisMath.mulDiv(activeDebt, interestFactor, attributes.getInterestPrecision());
            activeDebt = activeDebt + activeInterests;
        }

        return activeDebt.add(closedDebt);
    }

    function _getTCR(address _asset, uint256 _price) internal view returns (uint256 TCR) {
        uint256 entireSystemColl = getEntireSystemColl(_asset);
        uint256 entireSystemDebt = getEntireSystemDebt(_asset);

        TCR = StablisMath._computeCR(entireSystemColl, entireSystemDebt, _price);

        return TCR;
    }

    function _requireUserAcceptsFee(uint256 _fee, uint256 _amount, uint256 _maxFeePercentage) internal pure {
        uint256 feePercentage = _fee.mul(DECIMAL_PRECISION).div(_amount);
        require(feePercentage <= _maxFeePercentage, "Fee exceeds maximum");
    }

    function _calculateInterestIndex(address _asset) internal view returns (uint256 currentInterestIndex, uint256 interestFactor) {
        uint256 lastIndexUpdateCached = attributes.getLastActiveIndexUpdate(_asset);
        uint256 activeInterestIndexCached = attributes.getActiveInterestIndex(_asset);

        if (lastIndexUpdateCached == block.timestamp) return (activeInterestIndexCached, 0);
        uint256 currentInterest = attributes.getInterestRate(_asset);
        currentInterestIndex = activeInterestIndexCached; // we need to return this if it's already up to date
        if (currentInterest > 0) {
            /*
             * Calculate the interest accumulated and the new index:
             * We compound the index and increase the debt accordingly
             */
            uint256 deltaT = block.timestamp - lastIndexUpdateCached;
            interestFactor = deltaT * currentInterest;
            currentInterestIndex =
                currentInterestIndex +
                StablisMath.mulDiv(currentInterestIndex, interestFactor, attributes.getInterestPrecision());
        }
    }
}
