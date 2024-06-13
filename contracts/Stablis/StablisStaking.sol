// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/StablisMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Interfaces/IStablisToken.sol";
import "../Interfaces/IStablisStaking.sol";
import "../Interfaces/IUSDSToken.sol";
import "../Interfaces/ICommunityIssuance.sol";
import "../Interfaces/IChestManager.sol";

contract StablisStaking is IStablisStaking, OwnableUpgradeable, ReentrancyGuardUpgradeable, BaseMath, CheckContract {
    using SafeMathUpgradeable for uint;

    // --- Data ---
    string constant public NAME = "StablisStaking";
    address constant ETH_REF_ADDRESS = address(0);

    mapping(address => uint256) public stakes;
    mapping(address => bool) public boostedStakers;
    uint256 public totalStablisStaked;
    uint256 public totalBoostedStablisStaked;

    uint256 public nftBoostEnd;

    mapping(address => uint256) public F_asset;  // Running sum of asset fees per-Stablis-staked

    // User snapshots per asset, taken at the point at which their latest deposit was made
    mapping(address => mapping(address => uint256)) public snapshots;

    address[] public ASSET_TYPE;
    mapping(address => bool) public isAssetTracked;

    IStablisToken public stablisToken;
    IUSDSToken public usdsToken;
    IERC721 public ssbNft;
    ICommunityIssuance public communityIssuance;
    IChestManager public chestManager;

    address public borrowerOperationsAddress;
    address public activePoolAddress;

    // --- Functions ---

    function initialize
    (
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        override
        initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();

        checkContract(_dependencies.activePool);
        checkContract(_dependencies.borrowerOperations);
        checkContract(_dependencies.chestManager);
        checkContract(_dependencies.communityIssuance);
        checkContract(_dependencies.stablisNFT);
        checkContract(_dependencies.stablisToken);
        checkContract(_dependencies.usdsToken);

        activePoolAddress = _dependencies.activePool;
        borrowerOperationsAddress = _dependencies.borrowerOperations;
        chestManager = IChestManager(_dependencies.chestManager);
        communityIssuance = ICommunityIssuance(_dependencies.communityIssuance);
        ssbNft = IERC721(_dependencies.stablisNFT);
        stablisToken = IStablisToken(_dependencies.stablisToken);
        usdsToken = IUSDSToken(_dependencies.usdsToken);

        nftBoostEnd = block.timestamp + 183 days;

        transferOwnership(_multiSig);
    }

    // If caller has a pre-existing stake, send any accumulated ETH and USDS gains to them.
    function stake(uint256 _stablisAmount) external override nonReentrant {
        _requireNonZeroAmount(_stablisAmount);

        uint256 currentStake = stakes[msg.sender];

        _triggerSTSIssuance();

        uint256 assetLength = ASSET_TYPE.length;
        uint256 gain;
        address asset;

        // Grab any accumulated asset gains from the current stake and update snapshots
        for (uint256 i = 0; i < assetLength; i++) {
            asset = ASSET_TYPE[i];

            if (currentStake > 0) {
                gain = _getPendingAssetGain(asset, msg.sender);

                _sendAssetGainToUser(asset, gain);
                emit StakingGainsAssetWithdrawn(msg.sender, asset, gain);
            }

            _updateUserSnapshots(asset, msg.sender);
        }

        uint256 newStake = currentStake.add(_stablisAmount);

        // Increase user’s stake and total Stablis staked
        stakes[msg.sender] = newStake;
        totalStablisStaked = totalStablisStaked.add(_stablisAmount);
        emit TotalStablisStakedUpdated(totalStablisStaked);

        _updateBoost(currentStake, newStake);

        // Transfer Stablis from caller to this contract
        stablisToken.sendToStablisStaking(msg.sender, _stablisAmount);

        emit StakeChanged(msg.sender, newStake);
    }

    // Unstake the Stablis and send the it back to the caller, along with their accumulated USDS & ETH gains.
    // If requested amount > stake, send their entire stake.
    function unstake(uint256 _stablisAmount) external override nonReentrant {
        uint256 currentStake = stakes[msg.sender];
        _requireUserHasStake(currentStake);

        _triggerSTSIssuance();

        uint256 assetLength = ASSET_TYPE.length;
        address asset;
        uint256 assetGain;

        // Grab any accumulated ETH and USDS gains from the current stake
        for (uint256 i = 0; i < assetLength; i++) {
            asset = ASSET_TYPE[i];
            assetGain = _getPendingAssetGain(asset, msg.sender);

            _updateUserSnapshots(asset, msg.sender);
            emit StakingGainsAssetWithdrawn(msg.sender, asset, assetGain);
            _sendAssetGainToUser(asset, assetGain);
        }

        if (_stablisAmount > 0) {
            uint256 stablisToWithdraw = StablisMath._min(_stablisAmount, currentStake);

            uint256 newStake = currentStake.sub(stablisToWithdraw);

            // Decrease user's stake and total Stablis staked
            stakes[msg.sender] = newStake;
            totalStablisStaked = totalStablisStaked.sub(stablisToWithdraw);
            emit TotalStablisStakedUpdated(totalStablisStaked);

            _updateBoost(currentStake, newStake);

            // Transfer unstaked Stablis to user
            stablisToken.transfer(msg.sender, stablisToWithdraw);

            emit StakeChanged(msg.sender, newStake);
        }
    }

    function _updateBoost(uint256 prevStake, uint256 newStake) internal {
        bool isBoosted = boostedStakers[msg.sender];
        if (_isEligibleForStakingBoost(msg.sender)) {
            totalBoostedStablisStaked = totalBoostedStablisStaked
                .add(newStake)
                .sub(isBoosted ? prevStake : 0);
            boostedStakers[msg.sender] = true;

            emit TotalBoostedStablisStakedUpdated(totalBoostedStablisStaked);
            emit StakeBoosted(msg.sender);
        } else if (isBoosted) {
            totalBoostedStablisStaked = totalBoostedStablisStaked.sub(prevStake);
            boostedStakers[msg.sender] = false;

            emit TotalBoostedStablisStakedUpdated(totalBoostedStablisStaked);
            emit StakeBoostRemoved(msg.sender);
        }
    }

    // --- Reward-per-unit-staked increase functions. Called by Stablis core contracts ---

    function increaseF_Asset(address _asset, uint256 _assetFee) external override {
        _requireCallerIsChestManager();
        _increaseF_Asset(_asset, _assetFee);
    }

    function increaseF_USDS(uint256 _USDSFee) external override {
        _requireCallerIsBorrowerOperations();
        _increaseF_Asset(address(usdsToken), _USDSFee);
    }

    function _increaseF_Asset(address _asset, uint256 _assetFee) internal {
        if (!isAssetTracked[_asset]) {
            isAssetTracked[_asset] = true;
            ASSET_TYPE.push(_asset);
        }

        uint256 ETHFeePerStablisStaked;

        uint256 totalStake = (_asset == address(stablisToken)) ? totalBoostedStablisStaked : totalStablisStaked;

        /*
         * When the total stake is 0, F is not updated. The token issued can not be obtained by later
         * depositors - it is missed out on, and remains in the balance of the CommunityIssuance or the staking contract.
         *
         */
        if (totalStake == 0) {return;}

        ETHFeePerStablisStaked = _assetFee.mul(DECIMAL_PRECISION).div(totalStake);
        F_asset[_asset] = F_asset[_asset].add(ETHFeePerStablisStaked);
        emit F_AssetUpdated(_asset, F_asset[_asset]);
    }

    // --- Pending reward functions ---

    function getPendingAssetGain(address _asset, address _user) external view override returns (uint256) {
        return _getPendingAssetGain(_asset, _user);
    }

    function _getPendingAssetGain(address _asset, address _user) internal view returns (uint256) {
        uint256 F_Snapshot = snapshots[_user][_asset];
        uint256 staked;
        if (_asset == address(stablisToken)) {
            staked = boostedStakers[_user] ? stakes[_user] : 0;
        } else {
            staked = stakes[_user];
        }

        uint256 gain = staked.mul(F_asset[_asset].sub(F_Snapshot)).div(DECIMAL_PRECISION);
        return gain;
    }

    // --- Internal helper functions ---

    function _updateUserSnapshots(address _asset, address _user) internal {
        snapshots[_user][_asset] = F_asset[_asset];
        emit StakerSnapshotsUpdated(_user, F_asset[_asset]);
    }

    function _sendAssetGainToUser(address _asset, uint256 gain) internal {
        emit AssetSent(_asset, msg.sender, gain);
        if (_asset == ETH_REF_ADDRESS) {
            (bool success,) = msg.sender.call{value: gain}("");
            require(success, "StablisStaking: Failed to send accumulated AssetGain");
        } else {
            bool success = IERC20(_asset).transfer(msg.sender, gain);
            require(success, "StablisStaking: ERC20 transfer failed");
        }
    }

    function isStakingBoostActive() external view override returns (bool) {
        return _isStakingBoostActive();
    }

    function _isStakingBoostActive() internal view returns (bool) {
        return block.timestamp < nftBoostEnd;
    }

    function _isEligibleForStakingBoost(address _user) internal view returns (bool) {
        return _isStakingBoostActive() && ssbNft.balanceOf(_user) > 0;
    }

    function _triggerSTSIssuance() internal {
        uint256 stablisIssuance = communityIssuance.issueStablisSB();
        if (stablisIssuance == 0) {
            return;
        }
        _increaseF_Asset(address(stablisToken), stablisIssuance);
        communityIssuance.sendStablis(address(this), stablisIssuance);
    }

    // --- 'require' functions ---

    function _requireCallerIsChestManager() internal view {
        require(msg.sender == address(chestManager), "StablisStaking: caller is not ChestManager");
    }

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "StablisStaking: caller is not BorrowerOps");
    }

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "StablisStaking: caller is not ActivePool");
    }

    function _requireUserHasStake(uint256 currentStake) internal pure {
        require(currentStake > 0, 'StablisStaking: User must have a non-zero stake');
    }

    function _requireNonZeroAmount(uint256 _amount) internal pure {
        require(_amount > 0, 'StablisStaking: Amount must be non-zero');
    }

    receive() external payable {
        _requireCallerIsActivePool();
    }
}
