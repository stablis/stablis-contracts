// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IAttributes {
    // --- Structs ---
    struct AssetConfig {
        bool depositsEnabled;
        address priceAggregator;
        bool isERC4626;
        bool isDIA;
        string diaKey;
        uint256 interestRate;
        uint256 activeInterestIndex;
        uint256 lastActiveIndexUpdate;
    }

    struct Dependencies {
        address chestManager;
        address priceFeed;
    }

    // --- Events ---
    event MCRUpdated(uint256 _mcr);
    event USDSGasCompensationUpdated(uint256 _gasCompensation);
    event CollateralGasCompensationUpdated(uint256 _colGasCompensationPercentDivisor);
    event MinNetDebtUpdated(uint256 _minNetDebt);
    event BorrowingFeeFloorUpdated(uint256 _borrowingFeeFloor);
    event AssetAdded(address indexed _asset, bool _isERC4626);
    event DepositAllowedUpdated(address indexed _asset, bool _allowed);
    event MaxCollateralTypesUpdated(uint256 _maxCollateralTypes);
    event MaxGasCompensationUpdated(uint256 _maxGasCompensation);
    event PriceAggregatorContractUpdated(address indexed _asset, address _priceAggregator);
    event InterestRateUpdated(address indexed _asset, uint256 _interestRate, uint256 _interestRateInBPS);

    // --- Functions ---
    function getMCR() external view returns (uint256);
    function getUSDSGasCompensation() external view returns (uint256);
    function getColGasCompensationPercentDivisor() external view returns (uint256);
    function getMinNetDebt() external view returns (uint256);
    function getBorrowingFeeFloor() external view returns (uint256);
    function getIncentivesLp() external view returns (uint256);
    function getIncentivesSp() external view returns (uint256);
    function isDepositAllowed(address _asset) external view returns (bool);
    function getAsset(address _asset) external view returns (AssetConfig memory);
    function getAssets() external view returns (address[] memory);
    function getMaxCollateralTypes() external view returns (uint256);
    function getMaxGasCompensation() external view returns (uint256);
    function getPriceAggregator(address _asset) external view returns (address);
    function isERC4626(address _asset) external view returns (bool);
    function getDIA(address _asset) external view returns (bool isDIA, string memory);
    function getInterestRateInBPS(address _asset) external view returns (uint256);
    function getInterestRate(address _asset) external view returns (uint256);
    function getActiveInterestIndex(address _asset) external view returns (uint256);
    function getLastActiveIndexUpdate(address _asset) external view returns (uint256);
    function getInterestPrecision() external view returns (uint256);
    function getNitroPool() external view returns (address);
    function paused() external view returns (bool);

    function setMCR(uint256 _mcr) external;
    function setUSDSGasCompensation(uint256 _gasCompensation) external;
    function setColGasCompensationPercentDivisor(uint256 _colGasCompensationPercentDivisor) external;
    function setMinNetDebt(uint256 _minNetDebt) external;
    function setBorrowingFeeFloor(uint256 _borrowingFeeFloor) external;
    function setDepositAllowed(address _asset, bool _allowed) external;
    function addAsset(address _asset, bool _depositsEnabled, address _priceAggregator, bool isERC4626, bool _isDIA, string memory _diaKey, uint256 _interestRate) external;
    function setMaxCollateralTypes(uint256 _amount) external;
    function setMaxGasCompensation(uint256 _amount) external;
    function setPriceAggregator(address _asset, address _priceAggregator) external;
    function setInterestRateInBPS(address _asset, uint256 _interestRate) external;
    function setActiveInterestIndex(address _asset, uint256 _activeInterestIndex) external;
    function setLastActiveIndexUpdate(address _asset, uint256 _lastActiveIndexUpdate) external;
    function setNitroPool(address _nitroPool) external;
}
