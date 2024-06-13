// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface ICommunityIssuance {
    struct Dependencies {
        address stabilityPool;
        address stablisStaking;
        address stablisToken;
        address attributes;
    }
    // --- Events ---

    event TotalStablisIssuedSPUpdated(uint256 _totalStablisIssued);
    event TotalStablisIssuedLPUpdated(uint256 _totalStablisIssued);
    event TotalStablisIssuedSBUpdated(uint256 _totalStablisIssued);

    // --- Functions ---

    function initialize(
        Dependencies calldata _dependencies,
        address _multiSig
    ) external;

    function issueStablisSP() external returns (uint256);

    function issueStablisLP() external;

    function issueStablisSB() external returns (uint256);

    function sendStablis(address _account, uint256 _stablisAmount) external;
}
