// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;


/**
 * The purpose of this contract is to hold USDS tokens for gas compensation:
 * https://github.com/stablis/dev#gas-compensation
 * When a borrower opens a chest, an additional 50 USDS debt is issued,
 * and 50 USDS is minted and sent to this contract.
 * When a borrower closes their active chest, this gas compensation is refunded:
 * 50 USDS is burned from the this contract's balance, and the corresponding
 * 50 USDS debt on the chest is cancelled.
 * See this issue for more context: https://github.com/stablis/dev/issues/186
 */
contract GasPool {
  // do nothing, as the core contracts have permission to send to and burn from this address
}
