// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "../Dependencies/CheckContract.sol";
import {IStablisToken} from "../Interfaces/IStablisToken.sol";
import "../Interfaces/IVestingWalletFactory.sol";
import "./StablisVestingWallet.sol";

/*
* Based upon OpenZeppelin's ERC20 contract:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
*
* and their EIP2612 (ERC20Permit / ERC712) functionality:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/53516bc555a454862470e7860a9b5254db4d00f5/contracts/token/ERC20/ERC20Permit.sol
*
*
*  --- Functionality added specific to the StablisToken ---
*
* 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Stablis contracts) in external
* transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending Stablis directly to a Stablis
* core contract, when they should rather call the right function.
*
* 2) sendToStablisStaking(): callable only by Stablis core contracts, which move Stablis tokens from user -> StablisStaking contract.
*
* 3) Supply hard-capped at 100 million
*
* 4) CommunityIssuance and VestingWalletFactory addresses are set at deployment
*
* 5) The community reserves (bug bounties/hackathons/..) allocation of 5 million tokens is minted at deployment to an EOA

* 6) 42.95 million tokens are minted at deployment to the CommunityIssuance contract. 40.85 million of these are for the Stability Pool, and 2.1 million are for the Staking Boost
*
* 7) The LP rewards allocation of 2.15 million tokens is minted at deployment to a Staking contract
*
* 8) 46 million tokens are minted at deployment to the Stablis multisig
*
* 9) Until one year from deployment:
* -Stablis multisig may only transfer() tokens to VestingWallets that have been deployed via & registered in the
*  VestingWalletFactory
* -approve(), increaseAllowance(), decreaseAllowance() revert when called by the multisig
* -transferFrom() reverts when the multisig is the sender
* -sendToStablisStaking() reverts when the multisig is the sender, blocking the multisig from staking its Stablis.
*
* After one year has passed since deployment of the StablisToken, the restrictions on multisig operations are lifted
* and the multisig has the same rights as any other address.
*/

contract StablisToken is CheckContract, IStablisToken {
    using SafeMathUpgradeable for uint256;

    // --- ERC20 Data ---

    string constant internal _NAME = "Stablis";
    string constant internal _SYMBOL = "STS";
    string constant internal _VERSION = "1";
    uint8 constant internal  _DECIMALS = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    mapping(address => uint256) private _nonces;

    // --- StablisToken specific data ---

    uint256 public constant ONE_YEAR_IN_SECONDS = 365 days;

    // uint256 for use with SafeMath
    uint256 internal _1_MILLION = 1e24;     // 1e6 * 1e18 = 1e24
    uint256 internal _1_THOUSAND = 1e21;    // 1e3 * 1e18 = 1e21

    uint256 internal immutable deploymentStartTime;

    address public immutable communityIssuanceAddress;
    address public immutable stablisStakingAddress;
    address public immutable teamVestingWalletAddress;
    address public immutable treasuryVestingWalletAddress;

    IVestingWalletFactory public immutable vestingWalletFactory;

    // --- Structs ---

    struct Entitlements {
        uint256 poolsEntitlement;
        uint256 treasuryEntitlement;
        uint256 nftStakingBoostEntitlement;
        uint256 liquidityEntitlement;
        uint256 zealyCampaignEntitlement;
        uint256 usdsAirdropEntitlement;
        uint256 teamEntitlement;
        uint256 investorEntitlement;
        uint256 advisorEntitlement;
    }

    // --- Functions ---

    constructor
    (
        Dependencies memory _dependencies,
        address _treasuryAddress,
        address _lpLiquidityAddress,
        address _zealyCampaignAddress,
        address _teamAddress
    )
    {
        deploymentStartTime = block.timestamp;

        checkContract(_dependencies.communityIssuance);
        checkContract(_dependencies.stablisStaking);
        checkContract(_dependencies.vestingWalletFactory);

        communityIssuanceAddress = _dependencies.communityIssuance;
        stablisStakingAddress = _dependencies.stablisStaking;
        vestingWalletFactory = IVestingWalletFactory(_dependencies.vestingWalletFactory);

        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);

        // --- Initial Stablis allocations ---

        Entitlements memory entitlements = Entitlements({
            poolsEntitlement: _1_MILLION.mul(43),
            treasuryEntitlement: _1_MILLION.mul(10),
            nftStakingBoostEntitlement: _1_MILLION.mul(2).add(_1_THOUSAND.mul(100)),
            liquidityEntitlement: _1_MILLION.mul(4),
            zealyCampaignEntitlement: _1_THOUSAND.mul(300),
            usdsAirdropEntitlement: _1_THOUSAND.mul(600),
            teamEntitlement: _1_MILLION.mul(16),
            investorEntitlement: _1_MILLION.mul(20),
            advisorEntitlement: _1_MILLION.mul(4)
        });

        _mint(communityIssuanceAddress, (entitlements.poolsEntitlement).add(entitlements.nftStakingBoostEntitlement));
        _mint(_lpLiquidityAddress, entitlements.liquidityEntitlement);
        _mint(_zealyCampaignAddress, entitlements.zealyCampaignEntitlement);
        _mint(_dependencies.usdsAirdrop, entitlements.usdsAirdropEntitlement);
        _mint(address(vestingWalletFactory), (entitlements.investorEntitlement).add(entitlements.advisorEntitlement));

        StablisVestingWallet vestingWallet = new StablisVestingWallet(
            _teamAddress,
            uint64(ONE_YEAR_IN_SECONDS),
            uint64(ONE_YEAR_IN_SECONDS/2),
            0,
            0
        );
        teamVestingWalletAddress = address(vestingWallet);
        _mint(teamVestingWalletAddress, entitlements.teamEntitlement);

        StablisVestingWallet treasuryVestingWallet = new StablisVestingWallet(
            _treasuryAddress,
            uint64(ONE_YEAR_IN_SECONDS*15/10),
            uint64(ONE_YEAR_IN_SECONDS),
            0,
            0
        );
        treasuryVestingWalletAddress = address(treasuryVestingWallet);
        _mint(treasuryVestingWalletAddress, entitlements.treasuryEntitlement);
    }

    // --- External functions ---

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function getDeploymentStartTime() external view override returns (uint256) {
        return deploymentStartTime;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);

        // Otherwise, standard transfer functionality
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function sendToStablisStaking(address _sender, uint256 _amount) external override {
        _requireCallerIsStablisStaking();
        _transfer(_sender, stablisStakingAddress, _amount);
    }

    // --- EIP 2612 functionality ---

    function domainSeparator() public view override returns (bytes32) {
        if (_chainID() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit
    (
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        override
    {
        require(deadline >= block.timestamp, 'Stablis: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01',
            domainSeparator(), keccak256(abi.encode(
                _PERMIT_TYPEHASH, owner, spender, amount,
                _nonces[owner]++, deadline))));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress == owner, 'Stablis: invalid signature');
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view override returns (uint256) { // FOR EIP 2612
        return _nonces[owner];
    }

    // --- Internal operations ---

    function _chainID() private view returns (uint256 chainID) {
        assembly {
            chainID := chainid()
        }
    }

    function _buildDomainSeparator(bytes32 _typeHash, bytes32 _name, bytes32 _version) private view returns (bytes32) {
        return keccak256(abi.encode(_typeHash, _name, _version, _chainID(), address(this)));
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) &&
            _recipient != address(this),
            "Stablis: Cannot transfer tokens directly to the Stablis token contract or the zero address"
        );
        require(_recipient != communityIssuanceAddress,
            "Stablis: Cannot transfer tokens directly to the community issuance contract"
        );
    }

    function _requireCallerIsStablisStaking() internal view {
        require(msg.sender == stablisStakingAddress, "StablisToken: caller must be the stablisStaking contract");
    }

    // --- Optional functions ---

    function name() external pure override returns (string memory) {
        return _NAME;
    }

    function symbol() external pure override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external pure override returns (uint8) {
        return _DECIMALS;
    }

    function version() external pure override returns (string memory) {
        return _VERSION;
    }

    function permitTypeHash() external pure override returns (bytes32) {
        return _PERMIT_TYPEHASH;
    }
}
