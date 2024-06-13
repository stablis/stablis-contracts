// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import "./StablisVestingWallet.sol";
import {IStablisToken} from "../Interfaces/IStablisToken.sol";
import "../Interfaces/IVestingWalletFactory.sol";

/*
* The VestingWalletFactory deploys VestingWallets - its main purpose is to keep a registry of valid deployed VestingWallets.
*
* This registry is checked by StablisToken when the Stablis deployer attempts to transfer Stablis tokens. During the first year
* since system deployment, the Stablis deployer is only allowed to transfer Stablis to valid VestingWallets that have been
* deployed by and recorded in the VestingWalletFactory. This ensures the deployer's Stablis can't be traded or staked in the
* first year, and can only be sent to a verified VestingWallet which unlocks at least one year after system deployment.
*
* VestingWallet can of course be deployed directly, but only those deployed through and recorded in the VestingWalletFactory
* will be considered "valid" by StablisToken. This is a convenient way to verify that the target address is a genuine
* VestingWallet.
*/

contract VestingWalletFactory is IVestingWalletFactory, Ownable, Initializable {
    // --- Data ---
    string constant public NAME = "VestingWalletFactory";
    uint256 public tgeTimestamp;
    IStablisToken public stsToken;

    uint64 private constant SIX_MONTHS = 60 * 60 * 24 * 365 / 2;

    // --- Functions ---

    function initialize(address _stsToken) external initializer onlyOwner {
        stsToken = IStablisToken(_stsToken);
        tgeTimestamp = stsToken.getDeploymentStartTime();
        require(stsToken.balanceOf(address(this)) > 0, "VestingWalletFactory: STS balance must be > 0");
    }

    function deployVestingWallet(
        address _beneficiary,
        uint256 _amount
    ) external override onlyOwner {
        StablisVestingWallet vestingWallet = new StablisVestingWallet(
            _beneficiary,
            SIX_MONTHS,
            0,
            uint64(tgeTimestamp),
            2_000
        );
        require(stsToken.transfer(address(vestingWallet), _amount), "VestingWalletFactory: STS transfer failed");

        emit VestingWalletDeployedThroughFactory(address(vestingWallet), _beneficiary, uint64(tgeTimestamp), SIX_MONTHS, msg.sender);
    }
}
