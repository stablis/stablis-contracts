// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "./Interfaces/ICollSurplusPool.sol";
import "./Dependencies/StablisMath.sol";
import "./Dependencies/CheckContract.sol";

contract CollSurplusPool is OwnableUpgradeable, CheckContract, ICollSurplusPool {
    using SafeMathUpgradeable for uint256;

    string constant public NAME = "CollSurplusPool";

    address public borrowerOperationsAddress;
    address public chestManagerAddress;
    address public activePoolAddress;

    // deposited ether tracker
    mapping(address => uint256) internal ETH;
    // Collateral surplus claimable by chest owners
    mapping(address => mapping (address => uint256)) internal balances;

    // --- Contract setters ---

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
        checkContract(_dependencies.borrowerOperations);
        checkContract(_dependencies.chestManager);

        activePoolAddress = _dependencies.activePool;
        borrowerOperationsAddress = _dependencies.borrowerOperations;
        chestManagerAddress = _dependencies.chestManager;

        _transferOwnership(_multiSig);
    }

    /* Returns the ETH state variable at ActivePool address.
       Not necessarily equal to the raw ether balance - ether can be forcibly sent to contracts. */
    function getETH(address _asset) external view override returns (uint256) {
        return ETH[_asset];
    }

    function getCollateral(address _asset, address _account) external view override returns (uint256) {
        return balances[_asset][_account];
    }

    // --- Pool functionality ---

    function accountSurplus(address _asset, address _account, uint256 _amount) external override {
        _requireCallerIsChestManager();

        uint256 newAmount = balances[_asset][_account].add(_amount);
        balances[_asset][_account] = newAmount;

        emit CollBalanceUpdated(_asset, _account, newAmount);
    }

    function claimColl(address _asset, address _account) external override {
        _requireCallerIsBorrowerOperations();
        uint256 claimableColl = balances[_asset][_account];
        require(claimableColl > 0, "CollSurplusPool: No collateral available to claim");

        balances[_asset][_account] = 0;
        emit CollBalanceUpdated(_asset, _account, 0);

        ETH[_asset] = ETH[_asset].sub(claimableColl);
        emit EtherSent(_asset, _account, claimableColl);

        if(_asset == address(0)) {
            (bool success, ) = _account.call{ value: claimableColl }("");
            require(success, "CollSurplusPool: sending ETH failed");
        } else {
            SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(_asset), _account, StablisMath.decimalsCorrection(_asset, claimableColl));
        }
    }

    function receivedERC20(address _asset, uint256 _amount) external override {
        _requireCallerIsActivePool();
        ETH[_asset] = ETH[_asset].add(_amount);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(
            msg.sender == borrowerOperationsAddress,
            "CollSurplusPool: Caller is not Borrower Operations");
    }

    function _requireCallerIsChestManager() internal view {
        require(
            msg.sender == chestManagerAddress,
            "CollSurplusPool: Caller is not ChestManager");
    }

    function _requireCallerIsActivePool() internal view {
        require(
            msg.sender == activePoolAddress,
            "CollSurplusPool: Caller is not Active Pool");
    }

    // --- Fallback function ---

    receive() external payable {
        _requireCallerIsActivePool();
        ETH[address(0)] = ETH[address(0)].add(msg.value);
    }
}
