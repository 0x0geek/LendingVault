// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/LendingVault.sol";
import {BaseSetup} from "./BaseSetup.sol";

contract LendingVaultTest is BaseSetup {
    LendingVault public vault;

    uint8 internal constant ID_ETHER_POOL = 0;
    uint8 internal constant ID_USDC_POOL = 1;
    uint256 internal constant PERIOD_HALF_YEAR = 180;

    function setUp() public virtual override {
        BaseSetup.setUp();
        vault = new LendingVault();
    }

    function test_depositInUsdcPool() public {
        // when LP deposit 0, should revert
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vm.expectRevert(LendingVault.ZeroAmountForDeposit.selector);
        vault.deposit(ID_USDC_POOL, 0);
        vm.stopPrank();

        // when LP's USDC balance is less than the deposit mount, should revert
        vm.startPrank(edward);
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vm.expectRevert(LendingVault.InsufficientBalanceForDeposit.selector);
        vault.deposit(ID_USDC_POOL, 1000 * USDC_DECIMAL);
        vm.stopPrank();

        // deposit 1000 USDC successfully.
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 1000 * USDC_DECIMAL);
        vm.stopPrank();
    }

    function test_depositInEtherPool() public {
        // when LP deposit 0, should revert
        vm.startPrank(alice);
        vm.expectRevert(LendingVault.ZeroAmountForDeposit.selector);
        vault.deposit{value: 0}(ID_ETHER_POOL, 0);

        // if deposit amount is more than msg.value, amount should be msg.value
        vault.deposit{value: 9 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            10 * ETHER_DECIMAL
        );
        assertEq(address(vault).balance, 9 * ETHER_DECIMAL);

        // deposit 10 Ether successfully, amount should be 19 * ETHER_DECIMAL
        vault.deposit{value: 10 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            10 * ETHER_DECIMAL
        );
        assertEq(address(vault).balance, 19 * ETHER_DECIMAL);
        vm.stopPrank();
    }

    function test_borrowTokenFromUsdcPool() public {
        console.log("Vault usdc balance = %d", usdc.balanceOf(address(vault)));
        console.log("Vault ether balance = %d", address(vault).balance);

        // Alice deposit 1000 USDC to USDC/ETH pool
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 1000 USDC to USDC/ETH pool
        vm.startPrank(bob);
        usdc.approve(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob transfer 0 Ether and borrows X USDC, should revert
        vm.startPrank(carol);
        vm.expectRevert(LendingVault.ZeroCollateralAmountForBorrow.selector);
        vault.borrowToken{value: 0}(ID_USDC_POOL, 0, PERIOD_HALF_YEAR);

        // Bob transfer 1 Ether, but amount is 2 Ether, should revert
        vm.expectRevert(LendingVault.InsufficientCollateral.selector);
        vault.borrowToken{value: 1 * ETHER_DECIMAL}(
            ID_USDC_POOL,
            2 * ETHER_DECIMAL,
            PERIOD_HALF_YEAR
        );

        // Bob transfer 20 Ether, but LendingVault hasn't enough USDC balance, should revert
        vm.expectRevert(LendingVault.InsufficientTokenInBalance.selector);
        vault.borrowToken{value: 20 * ETHER_DECIMAL}(
            ID_USDC_POOL,
            20 * ETHER_DECIMAL,
            PERIOD_HALF_YEAR
        );

        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1e18
        }(ID_USDC_POOL, 1e18, PERIOD_HALF_YEAR);
        // Bob's borrow amount should be 1669914000
        assertEq(borrowAmount, 1669914000);
        // Bob's repay amount should be same with the vaule pulled from getRepayAmount()
        assertEq(repayAmount, vault.getRepayAmount(1));

        // If Bob already borrowed once, should revert
        vm.expectRevert(LendingVault.AlreadyBorrowed.selector);
        vault.borrowToken{value: 1e18}(ID_USDC_POOL, 1e18, PERIOD_HALF_YEAR);

        vm.stopPrank();
    }

    function test_borrowTokenFromEtherPool() public {
        console.log("Vault usdc balance = %d", usdc.balanceOf(address(vault)));
        console.log("Vault ether balance = %d", address(vault).balance);

        // Alice deposit 1 ether to ETH pool
        vm.startPrank(alice);
        vault.deposit{value: 1 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            1 * ETHER_DECIMAL
        );
        vm.stopPrank();

        // Bob deposit 3 ether to ETH pool
        vm.startPrank(bob);
        vault.deposit{value: 1 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            1 * ETHER_DECIMAL
        );
        vm.stopPrank();

        // Carol transfer 0 USDC and borrows X ETH, should revert
        vm.startPrank(carol);
        vm.expectRevert(LendingVault.ZeroCollateralAmountForBorrow.selector);
        vault.borrowToken(ID_ETHER_POOL, 0, PERIOD_HALF_YEAR);

        // Carol transfer 400000 USDC as his collateral, but he hasn't sufficient balance
        vm.expectRevert(LendingVault.InsufficientCollateral.selector);
        vault.borrowToken(
            ID_ETHER_POOL,
            4000000 * USDC_DECIMAL,
            PERIOD_HALF_YEAR
        );

        // Carol transfer 9000 USDC, but LendingVault hasn't enough Ether balance, should revert
        console.log("carol amunt = %d", usdc.balanceOf(address(carol)));
        usdc.approve(address(vault), 80000 * USDC_DECIMAL);
        vm.expectRevert(LendingVault.InsufficientTokenInBalance.selector);
        vault.borrowToken(
            ID_ETHER_POOL,
            80000 * USDC_DECIMAL,
            PERIOD_HALF_YEAR
        );

        usdc.approve(address(vault), 2000 * USDC_DECIMAL);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken(
            ID_ETHER_POOL,
            2000 * USDC_DECIMAL,
            PERIOD_HALF_YEAR
        );

        // Carol's borrow amount should be more than zero
        // 2000 * 80% (collateral factor) * 0.000539 (latest price from chainlink aggregator) / 100 / 10 ** 6
        assertGe(borrowAmount, 0);
        // Carol's repay amount should be same with the vaule pulled from getRepayAmount()
        assertEq(repayAmount, vault.getRepayAmount(ID_ETHER_POOL));

        // If Carol already borrowed once, should revert
        vm.expectRevert(LendingVault.AlreadyBorrowed.selector);
        vault.borrowToken(ID_ETHER_POOL, 2000 * USDC_DECIMAL, PERIOD_HALF_YEAR);

        vm.stopPrank();
    }

    function test_repayLoanInUsdcPool() public {
        // Alice deposit 1000 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 4000 USDC
        vm.startPrank(bob);
        usdc.approve(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Carol tries to repay 0 as the repay amount, but should revert, cause Carol hasnt a loan yet
        vm.startPrank(carol);
        vm.expectRevert(LendingVault.NotExistLoan.selector);
        vault.repayLoan(ID_USDC_POOL, 0);

        // Carol transfer 1 ether as collateral and receive X USDC
        vm.startPrank(carol);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1e18
        }(ID_USDC_POOL, 1e18, 180);
        assertGe(borrowAmount, 0);
        assertEq(repayAmount, vault.getRepayAmount(ID_USDC_POOL));

        // Carol repay 0 as the repay amount, should revert
        vm.expectRevert(LendingVault.ZeroRepayAmount.selector);
        vault.repayLoan(ID_USDC_POOL, 0);

        uint256 balanceBefore = address(carol).balance;

        // Carol repay and receive his collateral
        usdc.approve(address(vault), repayAmount);
        vault.repayLoan(ID_USDC_POOL, repayAmount);

        // After Carol repay amount, his collateral amount should be equal with the amount.
        assertEq(address(carol).balance, balanceBefore + 1 * ETHER_DECIMAL);

        vm.stopPrank();
    }

    function test_repayLoanInEtherPool() public {
        // Alice deposit 1000 USDC
        vm.startPrank(alice);
        vault.deposit{value: 2 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            2 * ETHER_DECIMAL
        );
        vm.stopPrank();

        // Bob deposit 4000 USDC
        vm.startPrank(bob);
        vault.deposit{value: 1 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            1 * ETHER_DECIMAL
        );
        vm.stopPrank();

        // Carol tries to repay 0 as the repay amount, but should revert, cause Carol hasnt a loan yet
        vm.startPrank(carol);
        vm.expectRevert(LendingVault.NotExistLoan.selector);
        vault.repayLoan(ID_ETHER_POOL, 0);

        // Carol transfer 1 ether as collateral and receive X USDC
        vm.startPrank(carol);
        usdc.approve(address(vault), 4000 * USDC_DECIMAL);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken(
            ID_ETHER_POOL,
            4000 * USDC_DECIMAL,
            180
        );
        assertGe(borrowAmount, 0);
        assertEq(repayAmount, vault.getRepayAmount(ID_ETHER_POOL));

        // Carol repay 0 as the repay amount, should revert
        vm.expectRevert(LendingVault.ZeroRepayAmount.selector);
        vault.repayLoan{value: 0}(ID_ETHER_POOL, 0);

        uint256 balanceBefore = usdc.balanceOf(address(carol));
        // Carol repay and receive his collateral
        vault.repayLoan{value: repayAmount}(ID_ETHER_POOL, repayAmount);

        // After Carol repay amount, his collateral amount should be equal with the amount.
        assertEq(
            usdc.balanceOf(address(carol)),
            balanceBefore + 4000 * USDC_DECIMAL
        );

        vm.stopPrank();
    }

    function test_withdrawInUsdcPool() public {
        // Alice tries to withdraw, but he hasn't deposited before, should revert
        vm.startPrank(alice);
        vm.expectRevert(LendingVault.ZeroAmountForWithdraw.selector);
        vault.withdraw(ID_USDC_POOL);

        // Alice deposit 1000 USDC
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 1000 * USDC_DECIMAL);

        uint256 balanceBefore = usdc.balanceOf(address(alice));
        // Alice withdraw
        vault.withdraw(ID_USDC_POOL);

        // After Carol withdraw, his USDC balance should be equal with the amount that he deposit before.
        assertEq(
            usdc.balanceOf(address(alice)),
            balanceBefore + 1000 * USDC_DECIMAL
        );
        vm.stopPrank();
    }

    function test_withdrawInEtherPool() public {
        // Alice tries to withdraw, but he hasn't deposited before, should revert
        vm.startPrank(alice);
        vm.expectRevert(LendingVault.ZeroAmountForWithdraw.selector);
        vault.withdraw(ID_ETHER_POOL);

        // Alice deposit 2 ether
        vault.deposit{value: 2 * ETHER_DECIMAL}(
            ID_ETHER_POOL,
            2 * ETHER_DECIMAL
        );

        uint256 balanceBefore = address(alice).balance;
        // Alice withdraw
        vault.withdraw(ID_ETHER_POOL);

        // After Carol withdraw, his ETH balance should be equal with the amount that he deposit before.
        assertEq(address(alice).balance, balanceBefore + 2 * ETHER_DECIMAL);
        vm.stopPrank();
    }

    function test_integrateTestInUsdcPool() public {
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 reward;

        // Alice deposit 1000 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 1000 * USDC_DECIMAL);
        vm.stopPrank();

        // Bob deposit 4000 USDC
        vm.startPrank(bob);
        usdc.approve(address(vault), 4000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 4000 * USDC_DECIMAL);
        vm.stopPrank();

        // Carol transfer 1 ether as collateral and receive X USDC
        vm.startPrank(carol);
        (uint256 borrowAmount, uint256 repayAmount) = vault.borrowToken{
            value: 1e18
        }(ID_USDC_POOL, 1e18, 180);
        assertGe(borrowAmount, 0);
        assertEq(repayAmount, vault.getRepayAmount(ID_USDC_POOL));
        vm.stopPrank();

        // David deposit 5000 USDC
        vm.startPrank(david);
        balanceBefore = usdc.balanceOf(address(david));

        usdc.approve(address(vault), 5000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 5000 * USDC_DECIMAL);
        // David withdraw his deposit again
        vault.withdraw(ID_USDC_POOL);

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
        vault.withdraw(ID_USDC_POOL);
        vm.stopPrank();
        balanceAfter = usdc.balanceOf(address(alice));
        reward = balanceAfter - balanceBefore - 1000 * USDC_DECIMAL;
        assertGe(reward, 0);
        console.log("Alice's reward = %d", reward);

        // David deposit 5000 USDC
        vm.startPrank(fraig);
        usdc.approve(address(vault), 3000 * USDC_DECIMAL);
        vault.deposit(ID_USDC_POOL, 3000 * USDC_DECIMAL);
        vm.stopPrank();

        // Alice withdraw and get reward
        balanceBefore = usdc.balanceOf(address(bob));
        vm.startPrank(bob);
        vault.withdraw(ID_USDC_POOL);
        vm.stopPrank();

        balanceAfter = usdc.balanceOf(address(bob));
        reward = balanceAfter - balanceBefore - 4000 * USDC_DECIMAL;
        assertGe(reward, 0);
        console.log("Bob's reward = %d", reward);

        // Carol repay and receive his collateral
        vm.startPrank(carol);
        usdc.approve(address(vault), repayAmount);
        vault.repayLoan(ID_USDC_POOL, repayAmount);
        vm.stopPrank();
    }
}
