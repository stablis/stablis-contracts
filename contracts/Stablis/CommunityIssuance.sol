// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../Interfaces/IStablisToken.sol";
import "../Interfaces/ICommunityIssuance.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/StablisMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Interfaces/IAttributes.sol";
import "../Interfaces/INitroPool.sol";

contract CommunityIssuance is ICommunityIssuance, OwnableUpgradeable, BaseMath, CheckContract {
    using SafeMathUpgradeable for uint;

    // --- Data ---

    string constant public NAME = "CommunityIssuance";

    uint256 constant public SECONDS_IN_ONE_MINUTE = 60;

    uint256 constant public MAX_BPS = 10_000;

    int256 constant public A_CONSTANT = -21423955453031;
    int256 constant public B_CONSTANT = 384798842;
    int256 constant public C_CONSTANT = 218250856;

    /*
    * The community Stablis supply cap is the starting balance of the Community Issuance contract.
    * It should be minted to this contract by StablisToken, when the token is deployed.
    */
    uint256 constant public poolsStablisSupplyCap = 43e24; // 43 million
    uint256 constant public stakingBoostStablisSupplyCap = 21e23; // 2.1 million

    uint256 constant public stakingBoostDuration = 183 days;

    IStablisToken public stablisToken;
    IAttributes public attributes;

    address public stabilityPoolAddress;
    address public stablisStakingAddress;

    uint256 public totalSPStablisIssued;
    uint256 public totalSPStablisReserved;
    uint256 public totalLPStablisIssued;
    uint256 public totalLPStablisReserved;
    uint256 public totalSBStablisIssued;

    uint256 public deploymentTime;

    // --- Functions ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        override
        initializer
    {
        deploymentTime = block.timestamp;

        __Ownable_init();

        checkContract(_dependencies.stabilityPool);
        checkContract(_dependencies.stablisStaking);
        checkContract(_dependencies.stablisToken);
        checkContract(_dependencies.attributes);

        stabilityPoolAddress = _dependencies.stabilityPool;
        stablisStakingAddress = _dependencies.stablisStaking;
        stablisToken = IStablisToken(_dependencies.stablisToken);
        attributes = IAttributes(_dependencies.attributes);

        // When stablisToken deployed, it should have transferred CommunityIssuance's Stablis entitlement
        uint256 stablisBalance = stablisToken.balanceOf(address(this));
        assert(stablisBalance >= poolsStablisSupplyCap + stakingBoostStablisSupplyCap);

        transferOwnership(_multiSig);
    }

    function issueStablisSP() external override returns (uint256) {
        _requireCallerIsStabilityPool();

        _issueStablisPools();

        uint256 issuance = totalSPStablisReserved;
        totalSPStablisIssued = totalSPStablisIssued + issuance;
        totalSPStablisReserved = 0;

        emit TotalStablisIssuedSPUpdated(totalSPStablisIssued);

        return issuance;
    }

    function issueStablisSB() external override returns (uint256) {
        _requireCallerIsStakingContract();

        uint256 timeElapsed = block.timestamp - deploymentTime;

        if (timeElapsed > stakingBoostDuration) {
            timeElapsed = stakingBoostDuration;
        }

        uint256 latestTotalStablisIssued = (stakingBoostStablisSupplyCap * timeElapsed) / stakingBoostDuration;
        uint256 issuance = latestTotalStablisIssued - totalSBStablisIssued;

        totalSBStablisIssued = latestTotalStablisIssued;
        emit TotalStablisIssuedSBUpdated(latestTotalStablisIssued);

        return issuance;
    }

    function issueStablisLP() external override {
        _issueStablisPools();

        address nitroPoolAddress = attributes.getNitroPool();
        if (nitroPoolAddress == address(0)) {
            return;
        }

        INitroPool nitroPool = INitroPool(nitroPoolAddress);
        if (nitroPool.settings().endTime <= block.timestamp) {
            return;
        }

        uint256 issuance = totalLPStablisReserved;
        totalLPStablisIssued = totalLPStablisIssued + issuance;
        totalLPStablisReserved = 0;

        emit TotalStablisIssuedLPUpdated(totalLPStablisIssued);
        stablisToken.approve(nitroPoolAddress, issuance);
        nitroPool.addRewards(issuance, 0);
    }

    function _issueStablisPools() internal {
        uint256 latestTotalStablisIssued = _getCumulativeIssuance();
        uint256 issuance = latestTotalStablisIssued - totalSPStablisIssued - totalLPStablisIssued
            - totalSPStablisReserved - totalLPStablisReserved;

        totalSPStablisReserved = totalSPStablisReserved + issuance * attributes.getIncentivesSp() / MAX_BPS;
        totalLPStablisReserved = totalLPStablisReserved + issuance * attributes.getIncentivesLp() / MAX_BPS;
    }

    function _getCumulativeIssuance() internal view returns (uint256) {
        // Get the time passed since deployment
        int256 timePassedInMinutes = int256(block.timestamp.sub(deploymentTime).div(SECONDS_IN_ONE_MINUTE));
        int256 DP = int256(DECIMAL_PRECISION);

        return StablisMath._min(poolsStablisSupplyCap, uint256(
            DP * A_CONSTANT * timePassedInMinutes ** 3 / 1e25
            + DP * B_CONSTANT * timePassedInMinutes ** 2 / 1e14
            + DP * C_CONSTANT * timePassedInMinutes / 1e7
        ));
    }

    function sendStablis(address _account, uint256 _stablisAmount) external override {
        _requireCallerIsSPOrStakingContract();

        stablisToken.transfer(_account, _stablisAmount);
    }

    // --- 'require' functions ---

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "CommunityIssuance: caller is not SP");
    }

    function _requireCallerIsStakingContract() internal view {
        require(msg.sender == stablisStakingAddress, "CommunityIssuance: caller is not the staking contract");
    }

    function _requireCallerIsSPOrStakingContract() internal view {
        require(
            msg.sender == stabilityPoolAddress || msg.sender == stablisStakingAddress,
            "CommunityIssuance: caller is neither SP nor staking contract"
        );
    }
}
