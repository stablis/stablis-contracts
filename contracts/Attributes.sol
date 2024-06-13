// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./Interfaces/IAttributes.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/IChestManager.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";

contract Attributes is IAttributes, BaseMath, OwnableUpgradeable, CheckContract, PausableUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using SafeMathUpgradeable for uint256;

    string constant public NAME = "Attributes";

    // Minimum collateral ratio for individual chests
    uint256 public MCR;

    // Amount of USDS to be locked in gas pool on opening chests
    uint256 public USDS_GAS_COMPENSATION;

    // Percentage of collateral to be drawn from a chest and sent as gas compensation on liquidation
    uint256 public COL_GAS_COMPENSATION_PERCENT_DIVISOR;

    // Minimum amount of net USDS debt a chest must have
    uint256 public MIN_NET_DEBT;

    uint256 public BORROWING_FEE_FLOOR;

    IPriceFeed public priceFeed;
    IChestManager public chestManager;

    uint256 public INCENTIVES_LP_BPS;
    uint256 public INCENTIVES_SP_BPS;
    address public nitroPool;

    EnumerableSetUpgradeable.AddressSet private _assets;
    mapping (address => AssetConfig) public assetConfigs;

    uint256 private _maxCollateralTypes;

    uint256 private _maxGasCompensation;

    uint256 constant public INTEREST_PRECISION = 1e27;

    uint256 constant public ONE_YEAR_IN_SECONDS = 365 days;

    uint256 constant public MAX_BPS = 100_00;

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    )
        external
        initializer
    {
        __Ownable_init();
        __Pausable_init();

        checkContract(_dependencies.priceFeed);
        checkContract(_dependencies.chestManager);
        require(_multiSig != address(0), "MultiSig cannot be zero address");

        priceFeed = IPriceFeed(_dependencies.priceFeed);
        chestManager = IChestManager(_dependencies.chestManager);

        MCR = 125e16; // 125%
        USDS_GAS_COMPENSATION = 10e18;
        MIN_NET_DEBT = 490e18;
        BORROWING_FEE_FLOOR = DECIMAL_PRECISION / 1000 * 5; // 0.5%
        COL_GAS_COMPENSATION_PERCENT_DIVISOR = 200; // dividing by 200 yields 0.5%
        _maxCollateralTypes = 90;
        _maxGasCompensation = 1e21;
        INCENTIVES_LP_BPS = 6666;
        INCENTIVES_SP_BPS = 3334;

        _transferOwnership(_multiSig);
    }

    function getMCR() public view override returns (uint256) {
        return MCR;
    }

    function setMCR(uint256 _mcr) external override onlyOwner {
        require(_mcr > DECIMAL_PRECISION, "MCR must be greater than 100%");
        MCR = _mcr;
        emit MCRUpdated(_mcr);
    }

    function getUSDSGasCompensation() public view override returns (uint256) {
        return USDS_GAS_COMPENSATION;
    }

    function setUSDSGasCompensation(uint256 _gasCompensation) external override onlyOwner {
        require (_gasCompensation <= _maxGasCompensation, "Gas compensation cannot be higher than max gas compensation");
        USDS_GAS_COMPENSATION = _gasCompensation;
        emit USDSGasCompensationUpdated(_gasCompensation);
    }

    function getColGasCompensationPercentDivisor() public view override returns (uint256) {
        return COL_GAS_COMPENSATION_PERCENT_DIVISOR;
    }

    function setColGasCompensationPercentDivisor(uint256 _colGasCompensationPercentDivisor) external override onlyOwner {
        COL_GAS_COMPENSATION_PERCENT_DIVISOR = _colGasCompensationPercentDivisor;
        emit CollateralGasCompensationUpdated(_colGasCompensationPercentDivisor);
    }

    function getMinNetDebt() public view override returns (uint256) {
        return MIN_NET_DEBT;
    }

    function setMinNetDebt(uint256 _minNetDebt) external override onlyOwner {
        MIN_NET_DEBT = _minNetDebt;
        emit MinNetDebtUpdated(_minNetDebt);
    }

    function getBorrowingFeeFloor() public view override returns (uint256) {
        return BORROWING_FEE_FLOOR;
    }

    function setBorrowingFeeFloor(uint256 _borrowingFeeFloor) external override onlyOwner {
        BORROWING_FEE_FLOOR = _borrowingFeeFloor;
        emit BorrowingFeeFloorUpdated(_borrowingFeeFloor);
    }

    function getIncentivesLp() public view override returns (uint256) {
        return INCENTIVES_LP_BPS;
    }

    function getIncentivesSp() public view override returns (uint256) {
        return INCENTIVES_SP_BPS;
    }

    function setIncentives(uint256 _incentivesSp, uint256 _incentivesLp) external onlyOwner {
        require(_incentivesSp.add(_incentivesLp) == MAX_BPS, "Incentives do not add up to 100%");
        INCENTIVES_SP_BPS = _incentivesSp;
        INCENTIVES_LP_BPS = _incentivesLp;
    }

    function isDepositAllowed(address _asset) public view returns (bool) {
        return assetConfigs[_asset].depositsEnabled;
    }

    function setDepositAllowed(address _asset, bool _allowed) external onlyOwner {
        require(_assets.contains(_asset), "Asset not in use");

        assetConfigs[_asset].depositsEnabled = _allowed;
        emit DepositAllowedUpdated(_asset, _allowed);
    }

    function getAsset(address _asset) external view override returns (AssetConfig memory) {
        return assetConfigs[_asset];
    }

    function getAssets() public view returns (address[] memory) {
        return _assets.values();
    }

    function addAsset(
        address _asset,
        bool _depositsEnabled,
        address _priceAggregator,
        bool _isERC4626,
        bool _isDIA,
        string memory _diaKey,
        uint256 _interestRateInBPS
    ) external onlyOwner {
        require(!_assets.contains(_asset), "Asset already exists");
        require(_assets.length() < _maxCollateralTypes, "Max collateral types reached");
        checkContract(_priceAggregator);

        uint256 _interestRate = _calculateInterestRate(_interestRateInBPS);

        assetConfigs[_asset] = AssetConfig({
            depositsEnabled: _depositsEnabled,
            priceAggregator: _priceAggregator,
            isERC4626: _isERC4626,
            isDIA: _isDIA,
            diaKey: _diaKey,
            interestRate: _interestRate,
            activeInterestIndex: INTEREST_PRECISION,
            lastActiveIndexUpdate: block.timestamp
        });
        _assets.add(_asset);

        priceFeed.setInitialPrice(_asset);

        emit AssetAdded(_asset, _isERC4626);
        emit DepositAllowedUpdated(_asset, _depositsEnabled);
        emit PriceAggregatorContractUpdated(_asset, _priceAggregator);
    }

    function getMaxCollateralTypes() external view override returns (uint256) {
        return _maxCollateralTypes;
    }

    function setMaxCollateralTypes(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Max collateral types cannot be zero");
        _maxCollateralTypes = _amount;
        emit MaxCollateralTypesUpdated(_amount);
    }

    function getMaxGasCompensation() external view override returns (uint256) {
        return _maxGasCompensation;
    }

    function setMaxGasCompensation(uint256 _amount) external onlyOwner {
        _maxGasCompensation = _amount;
        emit MaxGasCompensationUpdated(_amount);
    }

    function getPriceAggregator(address _asset) external view returns (address) {
        return assetConfigs[_asset].priceAggregator;
    }

    function setPriceAggregator(address _asset, address _priceAggregator) external onlyOwner {
        require(_assets.contains(_asset), "Asset not in use");
        checkContract(_priceAggregator);

        assetConfigs[_asset].priceAggregator = _priceAggregator;
        emit PriceAggregatorContractUpdated(_asset, _priceAggregator);
    }

    function isERC4626(address _asset) external view returns (bool) {
        return assetConfigs[_asset].isERC4626;
    }

    function getInterestRateInBPS(address _asset) external view returns (uint256) {
        return _calculateInterestRateInBPS(assetConfigs[_asset].interestRate);
    }

    function getInterestRate(address _asset) external view override returns (uint256) {
        return assetConfigs[_asset].interestRate;
    }

    function setInterestRateInBPS(address _asset, uint256 _interestRateInBPS) external onlyOwner {
        require(_assets.contains(_asset), "Asset not in use");

        uint256 _interestRate = _calculateInterestRate(_interestRateInBPS);
        chestManager.accrueActiveInterests(_asset);
        assetConfigs[_asset].interestRate = _interestRate;
        emit InterestRateUpdated(_asset, _interestRate, _interestRateInBPS);
    }

    function _calculateInterestRate(uint256 _interestRateInBPS) internal pure returns (uint256) {
        return (_interestRateInBPS * INTEREST_PRECISION) / (MAX_BPS * ONE_YEAR_IN_SECONDS);
    }

    function _calculateInterestRateInBPS(uint256 _interestRate) internal pure returns (uint256) {
        return Math.ceilDiv(_interestRate * MAX_BPS * ONE_YEAR_IN_SECONDS, INTEREST_PRECISION);
    }

    function getActiveInterestIndex(address _asset) external view returns (uint256) {
        return assetConfigs[_asset].activeInterestIndex;
    }

    function setActiveInterestIndex(address _asset, uint256 _activeInterestIndex) external {
        _requireCallerIsChestManager();
        assetConfigs[_asset].activeInterestIndex = _activeInterestIndex;
    }

    function getLastActiveIndexUpdate(address _asset) external view returns (uint256) {
        return assetConfigs[_asset].lastActiveIndexUpdate;
    }

    function setLastActiveIndexUpdate(address _asset, uint256 _lastActiveIndexUpdate) external {
        _requireCallerIsChestManager();
        assetConfigs[_asset].lastActiveIndexUpdate = _lastActiveIndexUpdate;
    }

    function getInterestPrecision() external pure returns (uint256) {
        return INTEREST_PRECISION;
    }

    function setNitroPool(address _nitroPool) external onlyOwner {
        checkContract(_nitroPool);
        nitroPool = _nitroPool;
    }

    function getNitroPool() external view override returns (address) {
        return nitroPool;
    }

    function _requireCallerIsChestManager() internal view {
        require(
            msg.sender == address(chestManager),
            "Attributes: Caller is not ChestManager");
    }

    function getDIA(address _asset) external view returns (bool, string memory) {
        return (assetConfigs[_asset].isDIA, assetConfigs[_asset].diaKey);
    }

    function paused() public view override (IAttributes, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
