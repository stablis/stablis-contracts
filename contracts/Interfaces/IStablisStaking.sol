// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IStablisStaking {
    struct Dependencies {
        address activePool;
        address borrowerOperations;
        address chestManager;
        address communityIssuance;
        address stablisNFT;
        address stablisToken;
        address usdsToken;
    }

    // --- Events --

    event StakeChanged(address indexed staker, uint256 newStake);
    event StakeBoosted(address indexed staker);
    event StakeBoostRemoved(address indexed staker);
    event StakingGainsAssetWithdrawn(address indexed staker, address _asset, uint256 ETHGain);
    event F_AssetUpdated(address _asset, uint256 _F_ETH);
    event TotalStablisStakedUpdated(uint256 _totalStablisStaked);
    event TotalBoostedStablisStakedUpdated(uint256 _totalBoostedStablisStaked);
    event AssetSent(address _asset, address _account, uint256 _amount);
    event StakerSnapshotsUpdated(address _staker, uint256 _F_ETH);

    // --- Functions ---

    function initialize
    (
        Dependencies calldata _dependencies,
        address _multiSig
    ) external;

    function stake(uint256 _stablisAmount) external;

    function unstake(uint256 _stablisAmount) external;

    function increaseF_Asset(address _asset, uint256 _ETHFee) external;

    function increaseF_USDS(uint256 _stablisFee) external;

    function getPendingAssetGain(address _asset, address _user) external view returns (uint256);

    function isStakingBoostActive() external view returns (bool);
}
