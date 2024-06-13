// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import "./Dependencies/BaseMath.sol";

import "./Interfaces/IChestManager.sol";
import "./Interfaces/IUSDSAirdrop.sol";

contract USDSAirdrop is IUSDSAirdrop, BaseMath, Ownable, Initializable {

    uint256 public immutable duration = 60 days;
    uint256 public finishAt;
    uint256 public updatedAt;
    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 public totalSupply;
    mapping(address => mapping(address => uint256)) public assetBalanceOf;
    mapping(address => uint256) public balanceOf; // total balance of an account for all assets

    IERC20 public stsToken;
    address public chestManager;

    modifier onlyAuthorized() {
        require(msg.sender == address(chestManager), "USDSAirdrop: not authorized");
        _;
    }

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    ) external initializer onlyOwner {
        chestManager = _dependencies.chestManager;
        stsToken = IERC20(_dependencies.stablisToken);

        uint256 rewardAmount = stsToken.balanceOf(address(this));
        require(rewardAmount > 0, "USDSAirdrop: reward amount is 0");
        _initializeRewards(rewardAmount);

        transferOwnership(_multiSig);
    }

    function lastTimeRewardApplicable() external view override returns (uint) {
        return _lastTimeRewardApplicable();
    }

    function rewardPerToken() external view override returns (uint) {
        return _rewardPerToken();
    }

    function earned(address _account) external view override returns (uint) {
        return _earned(_account);
    }

    function getReward() external override {
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            stsToken.transfer(msg.sender, reward);
        }
    }

    function updateStake(address _asset, address _account, uint256 _newStake) onlyAuthorized external {
        if (finishAt <= block.timestamp) {
            return;
        }

        _updateReward(_account);

        uint256 _oldStake = assetBalanceOf[_account][_asset];
        assetBalanceOf[_account][_asset] = _newStake;
        balanceOf[_account] = balanceOf[_account] - _oldStake + _newStake;
        totalSupply = totalSupply - _oldStake + _newStake;
    }

    function _initializeRewards(uint _amount) internal {
        rewardRate = (_amount * DECIMAL_PRECISION) / duration;
        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;
    }

    function _lastTimeRewardApplicable() internal view returns (uint) {
        return _min(finishAt, block.timestamp);
    }

    function _rewardPerToken() internal view returns (uint) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored +
            (((_lastTimeRewardApplicable() - updatedAt) * 1e18 * rewardRate) /
            totalSupply /
                DECIMAL_PRECISION);
    }

    function _earned(address _account) internal view returns (uint) {
        return
            ((balanceOf[_account] *
                (_rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18) +
            rewards[_account];
    }

    function _updateReward(address _account) internal {
        rewardPerTokenStored = _rewardPerToken();
        updatedAt = _lastTimeRewardApplicable();
        rewards[_account] = _earned(_account);
        userRewardPerTokenPaid[_account] = rewardPerTokenStored;
    }

    function _min(uint x, uint y) private pure returns (uint) {
        return x <= y ? x : y;
    }
}
