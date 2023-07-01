// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./libraries/Math.sol";
import "./libraries/ReEntrancyGuard.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

contract LendingVault is Ownable, ReEntrancyGuard {
    using SafeMath for uint256;
    using Math for uint256;

    address public constant AGGREGATOR_USDC_ETH =
        0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    address public constant USDC_TOKEN_ADDRESS =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant USDC_DECIMAL = 1e6;
    uint256 internal constant ETHER_DECIMAL = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant ETHER_DECIMAL_FACTOR = 10 ** 2;
    uint256 internal constant DISCOUNT_RATE = 95;

    struct Pool {
        bool isEtherLpToken;
        // Daily interest rate
        uint8 interestRate;
        // Fee for borrower
        uint8 reserveFeeRate;
        // Collateral factor
        uint8 collateralFactor;
        uint256 totalBorrowAmount;
        uint256 totalAssetAmount;
        uint256 totalReserveAmount;
        uint256 currentAmount;
    }

    struct Loan {
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 repayAmount;
        uint256 feeAmount;
        uint256 interestAmount;
        uint256 timestamp;
        uint256 duration;
    }

    struct Depositor {
        uint256 assetAmount;
        uint256 rewardDebt;
        uint256 lendingAmount;
    }

    IERC20 public usdcToken;
    Pool[] public pools;
    mapping(uint256 => mapping(address => Loan)) loans;
    mapping(uint256 => mapping(address => Depositor)) public depositors;

    AggregatorV3Interface internal usdcEthPriceFeed;
    event PoolCreated(uint32 poolId);
    event Deposited(uint32 poolId, address indexed depositor, uint256 amount);
    event Withdraw(uint32 poolId, uint256 amount);
    event BorrowToken(
        address indexed borrower,
        uint256 collateralAmount,
        uint256 borrowedAmount,
        uint256 dueTimestamp
    );

    event LoanRepaid(address indexed borrower, uint256 amount);
    event CollateralSold(
        address indexed borrower,
        uint256 collateralAmount,
        uint256 proceeds
    );

    error ZeroAmountForDeposit();
    error InsufficientBalanceForDeposit();
    error ZeroAmountForWithdraw();
    error NotAvailableAmountForWithdraw();
    error ZeroCollateralAmountForBorrow();
    error InsufficientBalanceForBorrow();
    error AlreadyBorrowed();
    error InsufficientCollateral();
    error InsufficientTokenInBalance();
    error NotExistLoan();
    error ZeroRepayAmount();
    error NotAvailableForWithdraw();
    error NotAvailableForLoanOwner();
    error LoanHasNoCollateral();
    error LoanNotInLiquidate();
    error ZeroAmountForExchange();
    error InsufficientBalanceForLiquidate();

    constructor() {
        usdcEthPriceFeed = AggregatorV3Interface(AGGREGATOR_USDC_ETH);
        usdcToken = IERC20(USDC_TOKEN_ADDRESS);

        createPool(10, 80, 0, true);
        createPool(20, 90, 0, false);
    }

    /**
     * @dev Create a new pool
     */
    function createPool(
        uint8 _interestRate,
        uint8 _collateralFactor,
        uint8 _reserveFeeRate,
        bool _isEtherLpToken
    ) internal onlyOwner {
        Pool memory pool;

        pool.interestRate = _interestRate;
        pool.collateralFactor = _collateralFactor;
        pool.reserveFeeRate = _reserveFeeRate;
        pool.isEtherLpToken = _isEtherLpToken;

        pools.push(pool);

        uint32 poolId = uint32(pools.length - 1);
        emit PoolCreated(poolId);
    }

    function deposit(
        uint32 _poolId,
        uint256 _amount
    ) external payable noReentrant {
        if (_amount == 0) revert ZeroAmountForDeposit();

        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        uint256 assetAmount;

        if (pool.isEtherLpToken) {
            if (msg.value == 0) revert ZeroAmountForDeposit();

            if (msg.value != _amount) _amount = msg.value;

            assetAmount = calculateAssetAmount(_poolId, _amount);
        } else {
            if (usdcToken.balanceOf(msg.sender) < _amount)
                revert InsufficientBalanceForDeposit();

            assetAmount = calculateAssetAmount(_poolId, _amount);

            usdcToken.transferFrom(msg.sender, address(this), _amount);
        }

        console.log("asset amount = %d", assetAmount);

        depositor.assetAmount += assetAmount;

        pool.currentAmount += _amount;
        pool.totalAssetAmount += assetAmount;

        emit Deposited(_poolId, msg.sender, _amount);
    }

    function withdraw(uint32 _poolId) external noReentrant {
        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        uint256 assetAmount = depositor.assetAmount;

        if (assetAmount == 0) revert ZeroAmountForWithdraw();

        // calculate amount user can withdraw
        uint256 amount = calculateAmount(_poolId, assetAmount);
        console.log("withdraw amount = %d", amount);
        console.log("current amount = %d", pool.currentAmount);
        console.log("total borrow amount = %d", pool.totalBorrowAmount);

        // update depositor's asset amount
        depositor.assetAmount -= assetAmount;

        if (amount > pool.currentAmount) revert NotAvailableForWithdraw();

        // update pool's current liquidity amount
        pool.currentAmount -= amount;
        // update pool's total asset amount
        pool.totalAssetAmount -= assetAmount;

        if (pool.isEtherLpToken) {
            payable(msg.sender).transfer(amount);
        } else {
            usdcToken.approve(msg.sender, amount);
            usdcToken.transfer(msg.sender, amount);
        }

        emit Withdraw(_poolId, amount);
    }

    function borrowToken(
        uint256 _poolId,
        uint256 _amount,
        uint256 _duration
    ) external payable noReentrant returns (uint256, uint256) {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][msg.sender];

        // check if borrower already rent
        if (loanData.collateralAmount > 0) revert AlreadyBorrowed();

        uint256 borrowableAmount;

        if (pool.isEtherLpToken) {
            if (_amount == 0) revert ZeroCollateralAmountForBorrow();

            // Borrower is going to borrow Ether
            if (usdcToken.balanceOf(msg.sender) < _amount)
                revert InsufficientCollateral();

            borrowableAmount = _amount
                .mul(getUsdcEthPrice())
                .mul(pool.collateralFactor)
                .div(100)
                .div(USDC_DECIMAL);

            // check if there is sufficient the borrowable USDC amount in Vault.
            if (address(this).balance < borrowableAmount)
                revert InsufficientTokenInBalance();

            usdcToken.transferFrom(msg.sender, address(this), _amount);
            loanData.collateralAmount = _amount;
        } else {
            if (msg.value == 0) revert ZeroCollateralAmountForBorrow();
            // Borrower is going to borrow USDC
            if (msg.value < _amount) revert InsufficientCollateral();

            borrowableAmount = _amount
                .mul(pool.collateralFactor)
                .mul(USDC_DECIMAL)
                .div(getUsdcEthPrice())
                .div(100);

            console.log("borrowable amount = %d", borrowableAmount);

            // check if there is sufficient the borrowable USDC amount in Vault.
            if (usdcToken.balanceOf(address(this)) < borrowableAmount)
                revert InsufficientTokenInBalance();

            // update borrower's collateral amount
            loanData.collateralAmount = msg.value;
        }

        // update borrower's borrow amount;
        loanData.borrowedAmount = borrowableAmount;
        // update borrower's borrwed timestamp;
        loanData.timestamp = block.timestamp;
        // update borrowing period;
        loanData.duration = _duration;

        // calculate repayment amount
        (
            uint256 repayAmount,
            uint256 interestAmount,
            uint256 feeAmount
        ) = calculateRepaymentAmount(_poolId, borrowableAmount, _duration);

        // set borrower's pay amount
        loanData.repayAmount = repayAmount;
        loanData.interestAmount = interestAmount;
        loanData.feeAmount = feeAmount;

        // update pool's total borrow amount
        pool.totalBorrowAmount += repayAmount;
        // update pool's total reserve amount
        pool.totalReserveAmount += feeAmount;
        // update pool's current liquidity amount
        pool.currentAmount -= borrowableAmount;

        // transfer Token to borrower
        if (pool.isEtherLpToken) {
            payable(msg.sender).transfer(borrowableAmount);
        } else {
            usdcToken.approve(msg.sender, borrowableAmount);
            usdcToken.transfer(msg.sender, borrowableAmount);
        }

        emit BorrowToken(
            msg.sender,
            _amount,
            borrowableAmount,
            loanData.timestamp + _duration
        );

        console.log("amount = %d", borrowableAmount);
        return (borrowableAmount, repayAmount);
    }

    function repayLoan(
        uint256 _poolId,
        uint256 _amount
    ) external payable noReentrant {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][msg.sender];

        // check if borrower has an active loan
        if (loanData.repayAmount == 0) revert NotExistLoan();

        // check if repay amount is bigger than zero
        if (pool.isEtherLpToken) {
            if (_amount == 0 || msg.value == 0) revert ZeroRepayAmount();

            // when transfer Ether, _amount should be equal with the real amount of Ether.
            _amount = msg.value;
        } else {
            if (_amount == 0 || usdcToken.balanceOf(msg.sender) == 0)
                revert ZeroRepayAmount();
        }

        // If Borrower repays the amount bigger than the current repay amount, _amount should be loanData.repayAmount
        if (_amount >= loanData.repayAmount) _amount = loanData.repayAmount;

        if (!pool.isEtherLpToken) {
            // Borrower repays the borrowable token as USDC
            usdcToken.transferFrom(msg.sender, address(this), _amount);
        }

        // update loan's repay amount
        loanData.repayAmount -= _amount;

        // update pools' total borrow amount
        pool.totalBorrowAmount -= _amount;
        pool.currentAmount += _amount;

        // If Borrower doesn't need to repay more, he can get his collateral
        if (loanData.repayAmount == 0) {
            // update borrower's borrow amount;
            loanData.borrowedAmount = 0;
            // update borrower's borrwed timestamp;
            loanData.timestamp = 0;
            // update borrowing period;
            loanData.duration = 0;
            // update user collateral amount;
            uint256 collateralAmount = loanData.collateralAmount;

            // update user collateral amount;
            loanData.collateralAmount = 0;

            if (pool.isEtherLpToken) {
                // Borrower receives the collateral as USDC token
                usdcToken.approve(msg.sender, collateralAmount);
                usdcToken.transfer(msg.sender, collateralAmount);
            } else {
                // Borrower receives the collateral as Ether
                payable(msg.sender).transfer(collateralAmount);
            }
        }

        emit LoanRepaid(msg.sender, _amount);
    }

    function liquidate(
        uint32 _poolId,
        address _account
    ) external payable noReentrant returns (uint256) {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][_account];

        // check if Loan owner call liquidate
        if (msg.sender == _account) revert NotAvailableForLoanOwner();

        uint256 collateralAmount = loanData.collateralAmount;

        // check if Loan has collateral
        if (collateralAmount == 0) revert LoanHasNoCollateral();

        // check if Loan is at liquidate state
        if (loanData.timestamp + loanData.duration > block.timestamp)
            revert LoanNotInLiquidate();

        uint256 payAmount = getPayAmountForLiquidateLoan(_poolId, _account);
        uint256 balanceAmount;

        if (pool.isEtherLpToken) {
            if (msg.value < payAmount) revert InsufficientBalanceForLiquidate();

            balanceAmount = usdcToken.balanceOf(address(this));

            if (payAmount > balanceAmount) payAmount = balanceAmount;

            // update loan's collateral amount
            loanData.collateralAmount = 0;
            // receive Ether from user and transfer Usdc with discount percent
            usdcToken.approve(msg.sender, payAmount);
            usdcToken.transferFrom(address(this), msg.sender, payAmount);
        } else {
            payAmount = getPayAmountForLiquidateLoan(_poolId, _account);

            // check if user's USDC token balance is less than amount
            if (usdcToken.balanceOf(msg.sender) < payAmount)
                revert InsufficientBalanceForLiquidate();

            // receive Usdc token and transfer Ether to user
            usdcToken.transferFrom(msg.sender, address(this), payAmount);

            // update loan data's collateral amount
            loanData.collateralAmount = 0;
            payable(msg.sender).transfer(loanData.collateralAmount);
        }

        // update pool's current amount
        pool.currentAmount += payAmount;
        pool.totalBorrowAmount -= loanData.repayAmount;

        // check if liquidate payment is more than loan's repay
        if (loanData.repayAmount < payAmount) {
            // update pool's reserve amount again
            pool.totalReserveAmount -= loanData.feeAmount;
            pool.totalReserveAmount +=
                payAmount -
                loanData.interestAmount -
                loanData.borrowedAmount;
        } else {
            // update pool's reserve amount again
            pool.totalReserveAmount -= loanData.feeAmount;
        }

        // update loan's data
        loanData.borrowedAmount = 0;
        loanData.feeAmount = 0;
        loanData.interestAmount = 0;
        loanData.repayAmount = 0;
        loanData.timestamp = 0;

        return collateralAmount;
    }

    function getPayAmountForLiquidateLoan(
        uint32 _poolId,
        address _account
    ) public view returns (uint256) {
        Pool memory pool = pools[_poolId];
        Loan memory loanData = loans[_poolId][_account];

        uint256 collateralAmount = loanData.collateralAmount;
        uint256 payAmount;

        if (pool.isEtherLpToken) {
            payAmount = collateralAmount
                .mul(getUsdcEthPrice())
                .mul(DISCOUNT_RATE)
                .div(100)
                .div(USDC_DECIMAL);
        } else {
            payAmount = collateralAmount
                .mul(DISCOUNT_RATE)
                .mul(USDC_DECIMAL)
                .div(getUsdcEthPrice())
                .div(100);
        }

        return payAmount;
    }

    function getRepayAmount(uint32 _poolId) public view returns (uint256) {
        Loan memory loanData = loans[_poolId][msg.sender];
        return loanData.repayAmount;
    }

    function getTotalLiquidity(uint32 _poolId) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];
        return
            pool.totalBorrowAmount.add(pool.currentAmount).sub(
                pool.totalReserveAmount
            );
    }

    function getUsdcEthPrice() internal view returns (uint256) {
        (, int256 answer, , , ) = usdcEthPriceFeed.latestRoundData();
        console.log("answer = %d", uint256(answer));
        // Convert the USDC/ETH price to a decimal value with 18 decimal places
        return uint256(answer);
    }

    // Function to calculate total repayment amount including interest and fees
    function calculateRepaymentAmount(
        uint256 _poolId,
        uint256 _loanAmount,
        uint256 _duration
    ) internal view returns (uint256, uint256, uint256) {
        Pool memory pool = pools[_poolId];
        // Calculate interest charged on the loan
        uint256 interestAmount = calculateInterest(
            _loanAmount,
            pool.interestRate,
            _duration
        );

        console.log("Interest amount = %d", interestAmount);

        // Calculate fees charged on the loan
        uint256 reserveFees = (_loanAmount * pool.reserveFeeRate) / 100;
        uint256 feeAmount = reserveFees;

        console.log("Fee amount = %d", feeAmount);

        // Calculate total amount due including interest and fees
        uint256 repayAmount = _loanAmount + interestAmount + feeAmount;

        return (repayAmount, interestAmount, feeAmount);
    }

    /*
    function calculateLinearInterest(
        uint256 _rate,
        uint256 _fromTimestamp,
        uint256 _toTimestamp
    ) internal pure returns (uint256) {
        return
            _rate.mul(_toTimestamp.sub(_fromTimestamp)).div(SECONDS_PER_YEAR);
    }
    */

    function calculateAmount(
        uint32 _poolId,
        uint256 _assetAmount
    ) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];

        uint256 totalLiquidityAmount = getTotalLiquidity(_poolId);
        console.log("totalLiquidityAmount = %d", totalLiquidityAmount);

        uint256 amount = _assetAmount.mul(totalLiquidityAmount).divCeil(
            pool.totalAssetAmount
        );

        return amount;
    }

    function calculateAssetAmount(
        uint32 _poolId,
        uint256 _amount
    ) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];

        uint256 totalLiquidityAmount = getTotalLiquidity(_poolId);
        console.log("totalLiquidityAmount = %d", totalLiquidityAmount);

        if (pool.totalAssetAmount == 0 || totalLiquidityAmount == 0)
            return _amount;

        console.log("totalAssetAmount = %d", pool.totalAssetAmount);

        uint256 assetAmount = _amount.mul(pool.totalAssetAmount).div(
            totalLiquidityAmount
        );

        return assetAmount;
    }

    function calculateInterest(
        uint256 _loanAmount,
        uint256 _interestRate,
        uint256 _duration
    ) internal pure returns (uint256) {
        // Calculate interest charged on the loan
        uint256 yearlyInterest = (_loanAmount * _interestRate) / 100;
        uint256 dailyInterest = yearlyInterest / 365;
        uint256 totalInterest = dailyInterest * _duration;

        return totalInterest;
    }
}
