// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/LendingVault.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseSetup} from "./BaseSetup.sol";

contract LendingVaultTest is BaseSetup {
    using SafeERC20 for IERC20;

    LendingVault public vault;

    uint256 internal constant PERIOD_180_DAYS = 180;
    uint256 internal constant SKIP_PERIOD_181_DAYS = 181 * 3600 * 24;

    function setUp() public virtual override {
        BaseSetup.setUp();

        // interest rate = 20, collateral factor = 90m and reserve fee rate = 0
        vault = new LendingVault(20, 90, 0);
    }

    function test_deposit() public {
        // when LP deposit 0, should revert
        vm.startPrank(alice);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vm.expectRevert(LendingVault.ZeroAmountForDeposit.selector);
        vault.deposit(0);
        vm.stopPrank();

        // when LP's USDC balance is less than the deposit mount, should revert
        vm.startPrank(edward);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vm.expectRevert(LendingVault.InsufficientBalanceForDeposit.selector);
        vault.deposit(1000 * USDC_DECIMAL);
        vm.stopPrank();

        // deposit 1000 USDC successfully.
        vm.startPrank(alice);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(1000 * USDC_DECIMAL);
        vm.stopPrank();
    }

    function test_borrowToken() public {
        console.log("Vault usdc balance = %d", usdc.balanceOf(address(vault)));
        console.log("Vault ether balance = %d", address(vault).balance);

        // Alice deposit 1000 USDC to USDC/ETH pool
        vm.startPrank(alice);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 1000 USDC to USDC/ETH pool
        vm.startPrank(bob);
        usdc.safeApprove(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob transfer 0 Ether and borrows X USDC, should revert
        vm.startPrank(carol);
        vm.expectRevert(LendingVault.ZeroCollateralAmountForBorrow.selector);
        vault.borrowToken{value: 0}(0, PERIOD_180_DAYS);

        // Bob transfer 1 Ether, but amount is 2 Ether, should revert
        vm.expectRevert(LendingVault.InsufficientCollateral.selector);
        vault.borrowToken{value: 1 * ETHER_DECIMAL}(
            2 * ETHER_DECIMAL,
            PERIOD_180_DAYS
        );

        // Bob transfer 20 Ether, but LendingVault hasn't enough USDC balance, should revert
        vm.expectRevert(LendingVault.InsufficientTokenInBalance.selector);
        vault.borrowToken{value: 20 * ETHER_DECIMAL}(
            20 * ETHER_DECIMAL,
            PERIOD_180_DAYS
        );

        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1e18
        }(1e18, PERIOD_180_DAYS);
        // Bob's borrow amount should be bigger than 1669913000
        assertGe(borrowAmount, 1667902000);
        // Bob's repay amount should be same with the vaule pulled from getRepayAmount()
        assertEq(repayAmount, vault.getRepayAmount());

        // If Bob already borrowed once, should revert
        vm.expectRevert(LendingVault.AlreadyBorrowed.selector);
        vault.borrowToken{value: 1e18}(1e18, PERIOD_180_DAYS);

        vm.stopPrank();
    }

    function test_repayLoan() public {
        // Alice deposit 1000 USDC
        vm.startPrank(alice);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 4000 USDC
        vm.startPrank(bob);
        usdc.safeApprove(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Carol tries to repay 0 as the repay amount, but should revert, cause Carol hasnt a loan yet
        vm.startPrank(carol);
        vm.expectRevert(LendingVault.NotExistLoan.selector);
        vault.repayLoan(0);

        // Carol transfer 1 ether as collateral and receive X USDC
        vm.startPrank(carol);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1e18
        }(1e18, 180);
        assertGe(borrowAmount, 0);
        assertEq(repayAmount, vault.getRepayAmount());

        // Carol repay 0 as the repay amount, should revert
        vm.expectRevert(LendingVault.ZeroRepayAmount.selector);
        vault.repayLoan(0);

        uint256 balanceBefore = address(carol).balance;

        // Carol repay and receive his collateral
        usdc.safeApprove(address(vault), repayAmount);
        vault.repayLoan(repayAmount);

        // After Carol repay amount, his collateral amount should be equal with the amount.
        assertEq(address(carol).balance, balanceBefore + 1 * ETHER_DECIMAL);

        vm.stopPrank();
    }

    function test_withdraw() public {
        // Alice tries to withdraw, but he hasn't deposited before, should revert
        vm.startPrank(alice);
        vm.expectRevert(LendingVault.ZeroAmountForWithdraw.selector);
        vault.withdraw();

        // Alice deposit 1000 USDC
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(1000 * USDC_DECIMAL);

        uint256 balanceBefore = usdc.balanceOf(address(alice));
        // Alice withdraw
        vault.withdraw();

        // After Carol withdraw, his USDC balance should be equal with the amount that he deposit before.
        assertEq(
            usdc.balanceOf(address(alice)),
            balanceBefore + 1000 * USDC_DECIMAL
        );
        vm.stopPrank();
    }

    function test_liquidate() public {
        // Alice deposit 1000 USDC
        vm.startPrank(alice);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 4000 USDC
        vm.startPrank(bob);
        usdc.safeApprove(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Alice tries to liquidate loan, but there is no loan yet, should revert
        vm.startPrank(alice);
        vm.expectRevert(LendingVault.LoanHasNoCollateral.selector);
        vault.liquidate(address(carol));
        vm.stopPrank();

        // Carol transfer 1 ether as collateral and receive X USDC
        vm.startPrank(carol);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1 * ETHER_DECIMAL
        }(1 * ETHER_DECIMAL, PERIOD_180_DAYS);
        assertGe(borrowAmount, 0);
        assertEq(repayAmount, vault.getRepayAmount());

        // Carol tries to liquidate his loan, should revert
        vm.expectRevert(LendingVault.NotAvailableForLoanOwner.selector);
        vault.liquidate(address(carol));

        vm.stopPrank();

        vm.startPrank(alice);
        // Alice tries to liquidate carol loan, but the loan is not in liquidate, should revert
        vm.expectRevert(LendingVault.LoanNotInLiquidate.selector);
        vault.liquidate(address(carol));
        vm.stopPrank();

        // Skip 181 days
        skip(SKIP_PERIOD_181_DAYS);

        // Edward tries to liquidate Carol's loan, but he hasn't sufficient balance, should revert
        vm.startPrank(edward);
        vm.expectRevert(LendingVault.InsufficientBalanceForLiquidate.selector);
        vault.liquidate(address(carol));
        vm.stopPrank();

        // Alice liquidate Carol's loan
        vm.startPrank(alice);
        usdc.safeApprove(
            address(vault),
            vault.getPayAmountForLiquidateLoan(address(carol))
        );
        uint256 collateralAmount = vault.liquidate(address(carol));
        assertEq(collateralAmount, 1 * ETHER_DECIMAL);
        vm.stopPrank();
    }

    function test_integrateTest() public {
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 reward;

        // Alice deposit 1000 USDC
        vm.startPrank(alice);
        usdc.safeApprove(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 4000 USDC
        vm.startPrank(bob);
        usdc.safeApprove(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Carol transfer 1 ether as collateral and receive X USDC
        vm.startPrank(carol);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1e18
        }(1e18, 180);
        assertGe(borrowAmount, 0);
        assertEq(repayAmount, vault.getRepayAmount());
        vm.stopPrank();

        // David deposit 5000 USDC
        vm.startPrank(david);
        balanceBefore = usdc.balanceOf(address(david));

        usdc.safeApprove(address(vault), 5000 * USDC_DECIMAL);
        vault.deposit(5000 * USDC_DECIMAL);
        // David withdraw his deposit again
        vault.withdraw();

        balanceAfter = usdc.balanceOf(address(david));
        console.log("David's balance before = %d", balanceBefore);
        console.log("David's balance after = %d", balanceAfter);
        reward = balanceAfter - balanceBefore;
        //David's reward is 0, because he deposited, after Carol borrow
        assertEq(reward, 0);
        vm.stopPrank();

        /*
         Alice's reward should be greater than zero, because Carol borrow Ether
         Alice deposit = 1000, his asset = 1000
         Bob deposit 4000 = 4000, his asset = 4000
         Carol's collateral =  1 ether, latestRoundData = 538949909995365 (0.00053894)
         Carol's borrow amount = 1 ether(10 ** 18) * 90 % (pool's collateral factor) * 10 ** 6 (Usdc decimal) / 538949909995365 (latestRoundData) / 100
         Then, Carol's borrow amount is 1669914000 ( 1669.914 USDC )
         And, Carol's repay amount is 1834.617780 USDC (1834617780) = 1669.914 + 164.703780 (interest amount) + 0 ( fee rate is 0)
         Based on Carol's interest amount 164.703780,
            Alice's reward = Alice's asset amount * (Pool's current amount + Pool's total borrow amount - Pool's total reserve amount)
            Alice's withdraw amount = 1000000000 * ((5000000000 - 1669914000) + 1834617780 - 0) / 5000000000 = 1032940756 (1032.940756)
            Alice's reward = 1032.940756 - 1000 = 32.940756
            Bob's reward = 164.703780 - 32.940756 = 131.763024
        */

        // Alice withdraw and get reward
        balanceBefore = usdc.balanceOf(address(alice));
        vm.startPrank(alice);
        vault.withdraw();
        vm.stopPrank();
        balanceAfter = usdc.balanceOf(address(alice));
        reward = balanceAfter - balanceBefore - 1000 * USDC_DECIMAL;
        assertGe(reward, 0);
        console.log("Alice's reward = %d", reward);

        // David deposit 5000 USDC
        vm.startPrank(fraig);
        usdc.safeApprove(address(vault), 3000 * USDC_DECIMAL);
        vault.deposit(3000 * USDC_DECIMAL);
        vm.stopPrank();

        // Alice withdraw and get reward
        balanceBefore = usdc.balanceOf(address(bob));
        vm.startPrank(bob);
        vault.withdraw();
        vm.stopPrank();

        balanceAfter = usdc.balanceOf(address(bob));
        reward = balanceAfter - balanceBefore - 4000 * USDC_DECIMAL;
        assertGe(reward, 0);
        console.log("Bob's reward = %d", reward);

        // Carol repay and receive his collateral
        vm.startPrank(carol);
        usdc.safeApprove(address(vault), repayAmount);
        vault.repayLoan(repayAmount);
        vm.stopPrank();
    }
}
