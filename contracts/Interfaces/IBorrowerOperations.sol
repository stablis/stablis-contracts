// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Common interface for the Chest Manager.
interface IBorrowerOperations {
    struct Dependencies {
        address activePool;
        address attributes;
        address chestManager;
        address collSurplusPool;
        address defaultPool;
        address gasPool;
        address priceFeed;
        address sortedChests;
        address stabilityPool;
        address stablisStaking;
        address usdsToken;
    }

    enum BorrowerOperation {
        openChest,
        closeChest,
        adjustChest
    }

    // --- Events ---

    event ChestCreated(address indexed _asset, address indexed _borrower, uint256 arrayIndex);
    event ChestUpdated(address indexed _asset, address indexed _borrower, uint256 _debt, uint256 _coll, uint256 stake, BorrowerOperation operation);
    event USDSBorrowingFeePaid(address indexed _asset, address indexed _borrower, uint256 _USDSFee);

    // --- Functions ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    ) external;

    function openChest(address _asset, uint256 _tokenAmount, uint256 _maxFee, uint256 _USDSAmount, address _upperHint, address _lowerHint) external payable;

    function addColl(address _asset, uint256 _tokenAmount, address _upperHint, address _lowerHint) external payable;

    function moveETHGainToChest(address _asset, uint256 _tokenAmount, address _user, address _upperHint, address _lowerHint) external payable;

    function withdrawColl(address _asset, uint256 _amount, address _upperHint, address _lowerHint) external;

    function withdrawUSDS(address _asset, uint256 _maxFee, uint256 _amount, address _upperHint, address _lowerHint) external;

    function repayUSDS(address _asset, uint256 _amount, address _upperHint, address _lowerHint) external;

    function closeChest(address _asset) external;

    function adjustChest(address _asset, uint256 _assetSent, uint256 _maxFee, uint256 _collWithdrawal, uint256 _debtChange, bool isDebtIncrease, address _upperHint, address _lowerHint) external payable;

    function claimCollateral(address _asset) external;

    function getCompositeDebt(uint256 _debt) external view returns (uint256);
}
