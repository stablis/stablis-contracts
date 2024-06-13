// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import './Interfaces/IDefaultPool.sol';
import "./Dependencies/StablisMath.sol";
import "./Dependencies/CheckContract.sol";

/*
 * The Default Pool holds the ETH and USDS debt (but not USDS tokens) from liquidations that have been redistributed
 * to active chests but not yet "applied", i.e. not yet recorded on a recipient active chest's struct.
 *
 * When a chest makes an operation that applies its pending ETH and USDS debt, its pending ETH and USDS debt is moved
 * from the Default Pool to the Active Pool.
 */
contract DefaultPool is IDefaultPool, OwnableUpgradeable, CheckContract {
    using SafeMathUpgradeable for uint256;

    string constant public NAME = "DefaultPool";

    address constant ETH_REF_ADDRESS = address(0);

    address public chestManagerAddress;
    address public activePoolAddress;

    mapping(address => uint256) internal ETH;
    mapping(address => uint256) internal USDSDebt;

    // --- Dependency setters ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        virtual
        initializer
    {
        __Ownable_init();

        checkContract(_dependencies.activePool);
        checkContract(_dependencies.chestManager);

        activePoolAddress = _dependencies.activePool;
        chestManagerAddress = _dependencies.chestManager;

        _transferOwnership(_multiSig);
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    * Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH(address _asset) external view override returns (uint256) {
        return ETH[_asset];
    }

    function getUSDSDebt(address _asset) external view override returns (uint256) {
        return USDSDebt[_asset];
    }

    // --- Pool functionality ---

    function sendETHToActivePool(address _asset, uint256 _amount) external override {
        _requireCallerIsChestManager();
        address activePool = activePoolAddress; // cache to save an SLOAD
        ETH[_asset] = ETH[_asset].sub(_amount);
        emit DefaultPoolETHBalanceUpdated(_asset, ETH[_asset]);
        emit EtherSent(_asset, activePool, _amount);

        if (_asset != ETH_REF_ADDRESS) {
            SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(_asset), activePool, StablisMath.decimalsCorrection(_asset, _amount));
            IDeposit(activePool).receivedERC20(_asset, _amount);
        } else {
            (bool success, ) = activePool.call{ value: _amount }("");
            require(success, "DefaultPool: sending ETH failed");
        }
    }

    function increaseUSDSDebt(address _asset, uint256 _amount) external override {
        _requireCallerIsChestManager();
        USDSDebt[_asset] = USDSDebt[_asset].add(_amount);
        emit DefaultPoolUSDSDebtUpdated(_asset, USDSDebt[_asset]);
    }

    function decreaseUSDSDebt(address _asset, uint256 _amount) external override {
        _requireCallerIsChestManager();
        USDSDebt[_asset] = USDSDebt[_asset].sub(_amount);
        emit DefaultPoolUSDSDebtUpdated(_asset, USDSDebt[_asset]);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
    }

    function _requireCallerIsChestManager() internal view {
        require(msg.sender == chestManagerAddress, "DefaultPool: Caller is not the ChestManager");
    }

    // --- Fallback function ---

    function receivedERC20(address _asset, uint256 _amount) external override {
        _requireCallerIsActivePool();
        ETH[_asset] = ETH[_asset].add(_amount);
        emit DefaultPoolETHBalanceUpdated(_asset, ETH[_asset]);
    }

    receive() external payable {
        _requireCallerIsActivePool();
        ETH[ETH_REF_ADDRESS] = ETH[ETH_REF_ADDRESS].add(msg.value);
        emit DefaultPoolETHBalanceUpdated(ETH_REF_ADDRESS, ETH[ETH_REF_ADDRESS]);
    }
}
