// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "./Interfaces/IActivePool.sol";
import "./Interfaces/IDeposit.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/StablisMath.sol";

/*
 * The Active Pool holds the ETH collateral and USDS debt (but not USDS tokens) for all active chests.
 *
 * When a chest is liquidated, it's ETH and USDS debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is OwnableUpgradeable, ReentrancyGuardUpgradeable, CheckContract, IActivePool {
    using SafeMathUpgradeable for uint256;

    string constant public NAME = "ActivePool";
    address constant ETH_REF_ADDRESS = address(0);

    address public borrowerOperationsAddress;
    address public chestManagerAddress;
    address public stabilityPoolAddress;
    address public defaultPoolAddress;
    address public collSurplusPoolAddress;

    mapping(address => uint256) internal ETH;
    mapping(address => uint256) internal USDSDebt;

    // --- Contract setters ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        initializer
    {
        checkContract(_dependencies.borrowerOperations);
        checkContract(_dependencies.chestManager);
        checkContract(_dependencies.collSurplusPool);
        checkContract(_dependencies.defaultPool);
        checkContract(_dependencies.stabilityPool);

        __ReentrancyGuard_init();
        __Ownable_init();

        borrowerOperationsAddress = _dependencies.borrowerOperations;
        chestManagerAddress = _dependencies.chestManager;
        collSurplusPoolAddress = _dependencies.collSurplusPool;
        defaultPoolAddress = _dependencies.defaultPool;
        stabilityPoolAddress = _dependencies.stabilityPool;

        _transferOwnership(_multiSig);
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    *Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH(address _asset) external view override returns (uint256) {
        return ETH[_asset];
    }

    function getUSDSDebt(address _asset) external view override returns (uint256) {
        return USDSDebt[_asset];
    }

    // --- Pool functionality ---
    function sendETH(
        address _asset,
        address _account,
        uint256 _amount
    ) external override nonReentrant {
        _requireCallerIsBOorChestMorSP();
        if (_amount == 0) return;

        ETH[_asset] = ETH[_asset].sub(_amount);

        if (_asset != ETH_REF_ADDRESS) {
            SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(_asset), _account, StablisMath.decimalsCorrection(_asset, _amount));

            if (isERC20DepositContract(_account)) {
                IDeposit(_account).receivedERC20(_asset, _amount);
            }
        } else {
            (bool success, ) = _account.call{ value: _amount }("");
            require(success, "ActivePool: sending ETH failed");
        }

        emit ActivePoolETHBalanceUpdated(_asset, ETH[_asset]);
        emit EtherSent(_asset, _account, _amount);
    }

    function increaseUSDSDebt(address _asset, uint256 _amount) external override {
        _requireCallerIsBOorChestM();
        USDSDebt[_asset] = USDSDebt[_asset].add(_amount);
        emit ActivePoolUSDSDebtUpdated(_asset, USDSDebt[_asset]);
    }

    function decreaseUSDSDebt(address _asset, uint256 _amount) external override {
        _requireCallerIsBOorChestMorSP();
        USDSDebt[_asset] = USDSDebt[_asset].sub(_amount);
        emit ActivePoolUSDSDebtUpdated(_asset, USDSDebt[_asset]);
    }

    function isERC20DepositContract(address _account) private view returns (bool) {
        return (_account == defaultPoolAddress ||
        _account == collSurplusPoolAddress ||
        _account == stabilityPoolAddress);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool");
    }

    function _requireCallerIsBOorChestMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == chestManagerAddress ||
            msg.sender == stabilityPoolAddress,
            "ActivePool: Caller is neither BorrowerOperations nor ChestManager nor StabilityPool");
    }

    function _requireCallerIsBOorChestM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == chestManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor ChestManager");
    }

    // --- Fallback function ---

    function receivedERC20(address _asset, uint256 _amount) external override {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        ETH[_asset] = ETH[_asset].add(_amount);
        emit ActivePoolETHBalanceUpdated(_asset, ETH[_asset]);
    }

    receive() external payable {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        ETH[ETH_REF_ADDRESS] = ETH[ETH_REF_ADDRESS].add(msg.value);
        emit ActivePoolETHBalanceUpdated(ETH_REF_ADDRESS, ETH[ETH_REF_ADDRESS]);
    }
}
