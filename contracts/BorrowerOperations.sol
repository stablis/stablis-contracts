// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IChestManager.sol";
import "./Interfaces/IUSDSToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedChests.sol";
import "./Interfaces/IStablisStaking.sol";
import "./Dependencies/StablisBase.sol";
import "./Dependencies/CheckContract.sol";

contract BorrowerOperations is StablisBase, OwnableUpgradeable, CheckContract, IBorrowerOperations {
    using SafeMathUpgradeable for uint256;
    string constant public NAME = "BorrowerOperations";

    // --- Connected contract declarations ---

    address public stabilityPoolAddress;
    address public gasPoolAddress;

    IChestManager public chestManager;
    ICollSurplusPool public collSurplusPool;
    IStablisStaking public stablisStaking;
    IUSDSToken public usdsToken;

    // A doubly linked list of Chests, sorted by their collateral ratios
    ISortedChests public sortedChests;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

     struct LocalVariables_adjustChest {
        address asset;
        uint256 tokenAmount;
        uint256 price;
        uint256 collChange;
        uint256 netDebtChange;
        bool isCollIncrease;
        uint256 debt;
        uint256 coll;
        uint256 oldICR;
        uint256 newICR;
        uint256 newTCR;
        uint256 USDSFee;
        uint256 newDebt;
        uint256 newColl;
        uint256 stake;
    }

    struct LocalVariables_openChest {
        address asset;
        uint256 tokenAmount;
        uint256 price;
        uint256 USDSFee;
        uint256 netDebt;
        uint256 compositeDebt;
        uint256 ICR;
        uint256 NICR;
        uint256 stake;
        uint256 arrayIndex;
        uint256 currentInterestIndex;
    }

    struct ContractsCache {
        IChestManager chestManager;
        IActivePool activePool;
        IUSDSToken usdsToken;
    }

    // --- Dependency setters ---

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
        checkContract(_dependencies.attributes);
        checkContract(_dependencies.chestManager);
        checkContract(_dependencies.collSurplusPool);
        checkContract(_dependencies.defaultPool);
        checkContract(_dependencies.gasPool);
        checkContract(_dependencies.priceFeed);
        checkContract(_dependencies.sortedChests);
        checkContract(_dependencies.stabilityPool);
        checkContract(_dependencies.stablisStaking);
        checkContract(_dependencies.usdsToken);

        activePool = IActivePool(_dependencies.activePool);
        attributes = IAttributes(_dependencies.attributes);
        chestManager = IChestManager(_dependencies.chestManager);
        collSurplusPool = ICollSurplusPool(_dependencies.collSurplusPool);
        defaultPool = IDefaultPool(_dependencies.defaultPool);
        gasPoolAddress = _dependencies.gasPool;
        priceFeed = IPriceFeed(_dependencies.priceFeed);
        sortedChests = ISortedChests(_dependencies.sortedChests);
        stabilityPoolAddress = _dependencies.stabilityPool;
        stablisStaking = IStablisStaking(_dependencies.stablisStaking);
        usdsToken = IUSDSToken(_dependencies.usdsToken);

        transferOwnership(_multiSig);
    }

    // --- Borrower Chest Operations ---

    function openChest(address _asset, uint256 _tokenAmount, uint256 _maxFeePercentage, uint256 _USDSAmount, address _upperHint, address _lowerHint) external payable override {
        ContractsCache memory contractsCache = ContractsCache(chestManager, activePool, usdsToken);
        LocalVariables_openChest memory vars;

        vars.asset = _asset;
        vars.tokenAmount = _getAmount(_asset, _tokenAmount, false);

        vars.price = priceFeed.fetchPrice(_asset);

        _requireValidMaxFeePercentage(_maxFeePercentage);
        _requireChestisNotActive(vars.asset, contractsCache.chestManager, msg.sender);
        _requireDepositAllowed(vars.asset);
        _requireNotPaused();
        _requireValidAmount(_asset, _tokenAmount);

        vars.USDSFee;
        vars.netDebt = _USDSAmount;

        vars.USDSFee = _triggerBorrowingFee(vars.asset, contractsCache.chestManager, contractsCache.usdsToken, _USDSAmount, _maxFeePercentage);
        vars.netDebt = vars.netDebt.add(vars.USDSFee);
        _requireAtLeastMinNetDebt(vars.netDebt);

        // ICR is based on the composite debt, i.e. the requested USDS amount + USDS borrowing fee + USDS gas comp.
        vars.compositeDebt = _getCompositeDebt(vars.netDebt);
        assert(vars.compositeDebt > 0);

        vars.ICR = StablisMath._computeCR(vars.tokenAmount, vars.compositeDebt, vars.price);
        vars.NICR = StablisMath._computeNominalCR(vars.tokenAmount, vars.compositeDebt);

        _requireICRisAboveMCR(vars.ICR);

        // Set the chest struct's properties
        contractsCache.chestManager.setChestStatus(vars.asset, msg.sender, 1);
        contractsCache.chestManager.increaseChestColl(vars.asset, msg.sender, vars.tokenAmount);
        contractsCache.chestManager.increaseChestDebt(vars.asset, msg.sender, vars.compositeDebt);
        vars.currentInterestIndex = contractsCache.chestManager.accrueActiveInterests(vars.asset);
        contractsCache.chestManager.setChestInterestIndex(vars.asset, msg.sender, vars.currentInterestIndex);

        contractsCache.chestManager.updateChestRewardSnapshots(vars.asset, msg.sender);
        vars.stake = contractsCache.chestManager.updateStakeAndTotalStakes(vars.asset, msg.sender);

        sortedChests.insert(vars.asset, msg.sender, vars.NICR, _upperHint, _lowerHint);
        vars.arrayIndex = contractsCache.chestManager.addChestOwnerToArray(vars.asset, msg.sender);
        emit ChestCreated(vars.asset, msg.sender, vars.arrayIndex);

        // Move the ether to the Active Pool, and mint the USDSAmount to the borrower
        _activePoolAddColl(vars.asset, contractsCache.activePool, vars.tokenAmount);
        _withdrawUSDS(vars.asset, contractsCache.activePool, contractsCache.usdsToken, msg.sender, _USDSAmount, vars.netDebt);
        // Move the USDS gas compensation to the Gas Pool
        _withdrawUSDS(vars.asset, contractsCache.activePool, contractsCache.usdsToken, gasPoolAddress, getUSDSGasCompensation(), getUSDSGasCompensation());

        emit ChestUpdated(vars.asset, msg.sender, vars.compositeDebt, vars.tokenAmount, vars.stake, BorrowerOperation.openChest);
        emit USDSBorrowingFeePaid(vars.asset, msg.sender, vars.USDSFee);
    }

    // Send ETH as collateral to a chest
    function addColl(address _asset, uint256 _tokenAmount, address _upperHint, address _lowerHint) external payable override {
        _requireNotPaused();
        _adjustChest(_asset, _getAmount(_asset, _tokenAmount, false), msg.sender, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    // Send ETH as collateral to a chest. Called by only the Stability Pool.
    function moveETHGainToChest(address _asset, uint256 _tokenAmount, address _borrower, address _upperHint, address _lowerHint) external payable override {
        _requireCallerIsStabilityPool();
        _adjustChest(_asset, _getAmount(_asset, _tokenAmount, false), _borrower, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw ETH collateral from a chest
    function withdrawColl(address _asset, uint256 _collWithdrawal, address _upperHint, address _lowerHint) external override {
        _adjustChest(_asset, 0, msg.sender, _collWithdrawal, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw USDS tokens from a chest: mint new USDS tokens to the owner, and increase the chest's debt accordingly
    function withdrawUSDS(address _asset, uint256 _maxFeePercentage, uint256 _USDSAmount, address _upperHint, address _lowerHint) external override {
        _requireNotPaused();
        _adjustChest(_asset, 0, msg.sender, 0, _USDSAmount, true, _upperHint, _lowerHint, _maxFeePercentage);
    }

    // Repay USDS tokens to a Chest: Burn the repaid USDS tokens, and reduce the chest's debt accordingly
    function repayUSDS(address _asset, uint256 _USDSAmount, address _upperHint, address _lowerHint) external override {
        _adjustChest(_asset, 0, msg.sender, 0, _USDSAmount, false, _upperHint, _lowerHint, 0);
    }

    function adjustChest(address _asset, uint256 _assetSent, uint256 _maxFeePercentage, uint256 _collWithdrawal, uint256 _USDSChange, bool _isDebtIncrease, address _upperHint, address _lowerHint) external payable override {
        uint256 collChange = _getAmount(_asset, _assetSent, true);
        if (_isDebtIncrease || collChange > 0) {
            _requireNotPaused();
        }
        _adjustChest(_asset, collChange, msg.sender, _collWithdrawal, _USDSChange, _isDebtIncrease, _upperHint, _lowerHint, _maxFeePercentage);
    }

    /*
    * _adjustChest(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
    *
    * It therefore expects either a positive msg.value, or a positive _collWithdrawal argument.
    *
    * If both are positive, it will revert.
    */
    function _adjustChest(address _asset, uint256 _assetSent, address _borrower, uint256 _collWithdrawal, uint256 _USDSChange, bool _isDebtIncrease, address _upperHint, address _lowerHint, uint256 _maxFeePercentage) internal {
        ContractsCache memory contractsCache = ContractsCache(chestManager, activePool, usdsToken);
        LocalVariables_adjustChest memory vars;

        vars.asset = _asset;
        require(
            msg.value == 0 || msg.value == _assetSent,
            "BorrowerOp: _AssetSent and Msg.value aren't the same!"
        );

        vars.price = priceFeed.fetchPrice(vars.asset);

        if (_isDebtIncrease) {
            _requireValidMaxFeePercentage(_maxFeePercentage);
            _requireNonZeroDebtChange(_USDSChange);
        }
        if (_assetSent > 0) {
            _requireDepositAllowed(vars.asset);
            _requireValidAmount(_asset, _assetSent);
        }
        _requireSingularCollChange(_collWithdrawal, _assetSent);
        _requireNonZeroAdjustment(_collWithdrawal, _USDSChange, _assetSent);
        _requireChestisActive(vars.asset, contractsCache.chestManager, _borrower);

        // Confirm the operation is either a borrower adjusting their own chest, or a pure ETH transfer from the Stability Pool to a chest
        assert(msg.sender == _borrower || (msg.sender == stabilityPoolAddress && _assetSent > 0 && _USDSChange == 0));

        contractsCache.chestManager.applyPendingRewards(vars.asset, _borrower);

        // Get the collChange based on whether or not ETH was sent in the transaction
        (vars.collChange, vars.isCollIncrease) = _getCollChange(_assetSent, _collWithdrawal);

        vars.netDebtChange = _USDSChange;

        // If the adjustment incorporates a debt increase, then trigger a borrowing fee
        if (_isDebtIncrease) {
            vars.USDSFee = _triggerBorrowingFee(vars.asset, contractsCache.chestManager, contractsCache.usdsToken,_USDSChange, _maxFeePercentage);
            vars.netDebtChange = vars.netDebtChange.add(vars.USDSFee); // The raw debt change includes the fee
        }

        vars.debt = contractsCache.chestManager.getChestDebt(vars.asset, _borrower);
        vars.coll = contractsCache.chestManager.getChestColl(vars.asset, _borrower);

        // Get the chest's old ICR before the adjustment, and what its new ICR will be after the adjustment
        vars.oldICR = StablisMath._computeCR(vars.coll, vars.debt, vars.price);
        vars.newICR = _getNewICRFromChestChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease, vars.price);
        assert(_collWithdrawal <= vars.coll);

        // Check the adjustment satisfies all conditions
        _requireValidAdjustment(vars);

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough USDS
        if (!_isDebtIncrease && _USDSChange > 0) {
            _requireAtLeastMinNetDebt(_getNetDebt(vars.debt).sub(vars.netDebtChange));
            _requireValidUSDSRepayment(vars.debt, vars.netDebtChange);
            _requireSufficientUSDSBalance(contractsCache.usdsToken, _borrower, vars.netDebtChange);
        }

        (vars.newColl, vars.newDebt) = _updateChestFromAdjustment(vars.asset, contractsCache.chestManager, _borrower, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        vars.stake = contractsCache.chestManager.updateStakeAndTotalStakes(vars.asset, _borrower);

        // Re-insert chest in to the sorted list
        uint256 newNICR = _getNewNominalICRFromChestChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        sortedChests.reInsert(vars.asset, _borrower, newNICR, _upperHint, _lowerHint);

        emit ChestUpdated(vars.asset, _borrower, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustChest);
        emit USDSBorrowingFeePaid(vars.asset, msg.sender,  vars.USDSFee);

        // Use the unmodified _USDSChange here, as we don't send the fee to the user
        _moveTokensAndETHfromAdjustment(
            vars.asset,
            contractsCache.activePool,
            contractsCache.usdsToken,
            msg.sender,
            vars.collChange,
            vars.isCollIncrease,
            _USDSChange,
            _isDebtIncrease,
            vars.netDebtChange
        );
    }

    function closeChest(address _asset) external override {
        IChestManager chestManagerCached = chestManager;
        IActivePool activePoolCached = activePool;
        IUSDSToken usdsTokenCached = usdsToken;

        _requireChestisActive(_asset, chestManagerCached, msg.sender);

        chestManagerCached.applyPendingRewards(_asset, msg.sender);

        uint256 coll = chestManagerCached.getChestColl(_asset, msg.sender);
        uint256 debt = chestManagerCached.getChestDebt(_asset, msg.sender);

        _requireSufficientUSDSBalance(usdsTokenCached, msg.sender, debt.sub(getUSDSGasCompensation()));

        chestManagerCached.removeStake(_asset, msg.sender);
        chestManagerCached.closeChest(_asset, msg.sender);

        emit ChestUpdated(_asset, msg.sender, 0, 0, 0, BorrowerOperation.closeChest);

        // Burn the repaid USDS from the user's balance and the gas compensation from the Gas Pool
        _repayUSDS(_asset, activePoolCached, usdsTokenCached, msg.sender, debt.sub(getUSDSGasCompensation()));
        _repayUSDS(_asset, activePoolCached, usdsTokenCached, gasPoolAddress, getUSDSGasCompensation());

        // Send the collateral back to the user
        activePoolCached.sendETH(_asset, msg.sender, coll);
    }

    /**
     * Claim remaining collateral from a redemption
     */
    function claimCollateral(address _asset) external override {
        // send ETH from CollSurplus Pool to owner
        collSurplusPool.claimColl(_asset, msg.sender);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(address _asset, IChestManager _chestManager, IUSDSToken _usdsToken, uint256 _USDSAmount, uint256 _maxFeePercentage) internal returns (uint256) {
        _chestManager.decayBaseRateFromBorrowing(_asset); // decay the baseRate state variable
        uint256 USDSFee = _chestManager.getBorrowingFee(_asset, _USDSAmount);

        _requireUserAcceptsFee(USDSFee, _USDSAmount, _maxFeePercentage);
        // Send USDS fee to the Stablis staking contract
        stablisStaking.increaseF_USDS(USDSFee);
        _usdsToken.mint(address(stablisStaking), USDSFee);

        return USDSFee;
    }

    function _getUSDValue(uint256 _coll, uint256 _price) internal pure returns (uint256) {
        uint256 usdValue = _price.mul(_coll).div(DECIMAL_PRECISION);

        return usdValue;
    }

    function _getCollChange(
        uint256 _collReceived,
        uint256 _requestedCollWithdrawal
    )
        internal
        pure
        returns(uint256 collChange, bool isCollIncrease)
    {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    // Update chest's coll and debt based on whether they increase or decrease
    function _updateChestFromAdjustment
    (
        address _asset,
        IChestManager _chestManager,
        address _borrower,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    )
        internal
        returns (uint256, uint256)
    {
        uint256 newColl = (_isCollIncrease) ? _chestManager.increaseChestColl(_asset, _borrower, _collChange)
                                        : _chestManager.decreaseChestColl(_asset, _borrower, _collChange);
        uint256 newDebt = (_isDebtIncrease) ? _chestManager.increaseChestDebt(_asset, _borrower, _debtChange)
                                        : _chestManager.decreaseChestDebt(_asset, _borrower, _debtChange);

        return (newColl, newDebt);
    }

    function _moveTokensAndETHfromAdjustment
    (
        address _asset,
        IActivePool _activePool,
        IUSDSToken _usdsToken,
        address _borrower,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _USDSChange,
        bool _isDebtIncrease,
        uint256 _netDebtChange
    )
        internal
    {
        if (_isDebtIncrease) {
            _withdrawUSDS(_asset, _activePool, _usdsToken, _borrower, _USDSChange, _netDebtChange);
        } else {
            _repayUSDS(_asset, _activePool, _usdsToken, _borrower, _USDSChange);
        }

        if (_isCollIncrease) {
            _activePoolAddColl(_asset, _activePool, _collChange);
        } else {
            _activePool.sendETH(_asset, _borrower, _collChange);
        }
    }

    // Send ETH to Active Pool and increase its recorded ETH balance
    function _activePoolAddColl(address _asset, IActivePool _activePool, uint256 _amount) internal {
        if(_asset == address(0)) {
            (bool success, ) = address(_activePool).call{value: _amount}("");
            require(success, "BorrowerOps: Sending ETH to ActivePool failed");
        } else {
            SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(_asset), msg.sender, address(_activePool), StablisMath.decimalsCorrection(_asset, _amount));
            _activePool.receivedERC20(_asset, _amount);
        }
    }

    // Issue the specified amount of USDS to _account and increases the total active debt (_netDebtIncrease potentially includes a USDSFee)
    function _withdrawUSDS(address _asset, IActivePool _activePool, IUSDSToken _usdsToken, address _account, uint256 _USDSAmount, uint256 _netDebtIncrease) internal {
        _activePool.increaseUSDSDebt(_asset, _netDebtIncrease);
        _usdsToken.mint(_account, _USDSAmount);
    }

    // Burn the specified amount of USDS from _account and decreases the total active debt
    function _repayUSDS(address _asset, IActivePool _activePool, IUSDSToken _usdsToken, address _account, uint256 _USDS) internal {
        _activePool.decreaseUSDSDebt(_asset, _USDS);
        _usdsToken.burn(_account, _USDS);
    }

    // --- 'Require' wrapper functions ---

    function _requireSingularCollChange(uint256 _collWithdrawal, uint256 _assetSent) internal pure {
        require(_collWithdrawal == 0 || _assetSent == 0, "BorrowerOperations: Cannot withdraw and add coll");
    }

    function _requireNonZeroAdjustment(uint256 _collWithdrawal, uint256 _USDSChange, uint256 _assetSent) internal pure {
        require(_collWithdrawal != 0 || _USDSChange != 0 || _assetSent != 0, "BorrowerOps: There must be either a collateral change or a debt change");
    }

    function _requireDepositAllowed(address _asset) internal view {
        require(attributes.isDepositAllowed(_asset), "BorrowerOps: Deposit is not allowed for this asset");
    }

    function _requireChestisActive(address _asset, IChestManager _chestManager, address _borrower) internal view {
        uint256 status = _chestManager.getChestStatus(_asset, _borrower);
        require(status == 1, "BorrowerOps: Chest does not exist or is closed");
    }

    function _requireChestisNotActive(address _asset, IChestManager _chestManager, address _borrower) internal view {
        uint256 status = _chestManager.getChestStatus(_asset, _borrower);
        require(status != 1, "BorrowerOps: Chest is active");
    }

    function _requireNonZeroDebtChange(uint256 _USDSChange) internal pure {
        require(_USDSChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
    }

    function _requireValidAdjustment
    (
        LocalVariables_adjustChest memory _vars
    )
        internal
        view
    {
        _requireICRisAboveMCR(_vars.newICR);
    }

    function _requireICRisAboveMCR(uint256 _newICR) internal view {
        require(_newICR >= getMCR(), "BorrowerOps: An operation that would result in ICR < MCR is not permitted");
    }

    function _requireAtLeastMinNetDebt(uint256 _netDebt) internal view {
        require (_netDebt >= getMinNetDebt(), "BorrowerOps: Chest's net debt must be greater than minimum");
    }

    function _requireValidUSDSRepayment(uint256 _currentDebt, uint256 _debtRepayment) internal view {
        require(_debtRepayment <= _currentDebt.sub(getUSDSGasCompensation()), "BorrowerOps: Amount repaid must not be larger than the Chest's debt");
    }

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "BorrowerOps: Caller is not Stability Pool");
    }

     function _requireSufficientUSDSBalance(IUSDSToken _usdsToken, address _borrower, uint256 _debtRepayment) internal view {
        require(_usdsToken.balanceOf(_borrower) >= _debtRepayment, "BorrowerOps: Caller doesnt have enough USDS to make repayment");
    }

    function _requireValidMaxFeePercentage(uint256 _maxFeePercentage) internal view {
        require(_maxFeePercentage >= getBorrowingFeeFloor() && _maxFeePercentage <= DECIMAL_PRECISION,
            "Max fee percentage must be between 0.5% and 100%");
    }

    function _requireValidAmount(address _asset, uint256 _amount) internal view {
        if (_asset == address(0)) { return; }
        if (_amount == 0) { return; }
        uint8 decimals = IERC20MetadataUpgradeable(_asset).decimals();
        require(decimals <= 18, "Token has more than 18 decimals");

        if (decimals < 18) {
            uint256 base = 10**(18 - decimals);
            uint256 remainder = _amount % base;
            require(remainder == 0, "Invalid amount");
        }
    }

    function _requireNotPaused() internal view {
        require(!attributes.paused(), "BorrowerOps: Protocol is paused");
    }

    // --- ICR and TCR getters ---

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewNominalICRFromChestChange
    (
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    )
        pure
        internal
        returns (uint256)
    {
        (uint256 newColl, uint256 newDebt) = _getNewChestAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint256 newNICR = StablisMath._computeNominalCR(newColl, newDebt);
        return newNICR;
    }

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromChestChange
    (
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease,
        uint256 _price
    )
        pure
        internal
        returns (uint256)
    {
        (uint256 newColl, uint256 newDebt) = _getNewChestAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint256 newICR = StablisMath._computeCR(newColl, newDebt, _price);
        return newICR;
    }

    function _getNewChestAmounts(
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    )
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 newColl = _coll;
        uint256 newDebt = _debt;

        newColl = _isCollIncrease ? _coll.add(_collChange) :  _coll.sub(_collChange);
        newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

        return (newColl, newDebt);
    }

    function _getNewTCRFromChestChange
    (
        address _asset,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease,
        uint256 _price
    )
        internal
        view
        returns (uint256)
    {
        uint256 totalColl = getEntireSystemColl(_asset);
        uint256 totalDebt = getEntireSystemDebt(_asset);

        totalColl = _isCollIncrease ? totalColl.add(_collChange) : totalColl.sub(_collChange);
        totalDebt = _isDebtIncrease ? totalDebt.add(_debtChange) : totalDebt.sub(_debtChange);

        uint256 newTCR = StablisMath._computeCR(totalColl, totalDebt, _price);
        return newTCR;
    }

    function getCompositeDebt(uint256 _debt) external view override returns (uint256) {
        return _getCompositeDebt(_debt);
    }

    function _getAmount(
        address _asset,
        uint256 _amount,
        bool canBeZero
    ) internal view returns (uint256) {
        bool isEth = _asset == address(0);

        if (isEth) {
            _amount = msg.value;
        } else {
            require(msg.value == 0, "BorrowerOp: msg.value must be 0 for non-ETH assets");
        }

        require(
            canBeZero || _amount > 0,
            "BorrowerOp: Invalid Input. Override msg.value only if using ETH asset, otherwise use _amount"
        );

        return _amount;
    }
}
