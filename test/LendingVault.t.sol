// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/LendingVault.sol";

contract LendingVaultTest is Test {
    LendingVault public vault;

    function setUp() public {
        vault = new LendingVault();
    }
}
