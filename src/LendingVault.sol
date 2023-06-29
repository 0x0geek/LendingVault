// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./VaultCounter.sol";

contract LendingVault is Ownable {
    using SafeMath for uint256;
    using VaultCounterLibrary for Vault;

    address public constant AGGREGATOR_USDC_ETH =
        0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    address public constant USDC_TOKEN_ADDRESS =
        0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    struct Pool {
        bool isEtherLpToken;
        // Daily interest rate
        uint8 interestRate;
        // Fee for borrower
        uint8 originalFeeRate;
        // Collateral factor
        uint8 collateralFactor;
        uint256 depositTokenAmount;
        uint256 earnedReward;
        uint256 lastRewardedBlock;
        Vault totalAsset;
        Vault totalBorrow;
    }

    struct Loan {
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 repayAmount;
        uint256 timestamp;
        uint256 duration;
        uint256 interest;
    }

    struct Depositor {
        uint256 amount;
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
    event Withdraw(uint32 poolId);
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

    error ZeroDepositAmount();
    error InsufficientBalanceForDeposit();
    error ZeroAmountForWithdraw();
    error NotAvailableAmountForWithdraw();
    error AlreadyBorrowed();
    error InsufficientCollateral();
    error InsufficientTokenInBalance();
    error NotExistLoan();
    error ZeroRepayAmount();

    constructor() {
        usdcEthPriceFeed = AggregatorV3Interface(AGGREGATOR_USDC_ETH);
        usdcToken = IERC20(USDC_TOKEN_ADDRESS);

        createPool(1, 80, 2, true);
        createPool(2, 90, 1, false);
    }

    /**
     * @dev Create a new pool
     */
    function createPool(
        uint8 _interestRate,
        uint8 _collateralFactor,
        uint8 _originalFeeRate,
        bool _isEtherLpToken
    ) internal onlyOwner {
        Pool memory pool;

        pool.interestRate = _interestRate;
        pool.collateralFactor = _collateralFactor;
        pool.originalFeeRate = _originalFeeRate;
        pool.isEtherLpToken = _isEtherLpToken;

        pools.push(pool);

        uint32 poolId = uint32(pools.length - 1);
        emit PoolCreated(poolId);
    }

    function deposit(uint256 _poolId, uint256 _amount) external payable {
        if (_amount == 0) revert ZeroDepositAmount();

        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        if (pool.isEtherLpToken) {
            if (msg.value == 0) revert ZeroDepositAmount();
        } else {
            if (usdcToken.balanceOf(msg.sender) < _amount)
                revert InsufficientBalanceForDeposit();

            usdcToken.transferFrom(msg.sender, address(this), _amount);
        }

        depositor.amount += _amount;

        uint256 shares = pool.totalAsset.toShares(_amount, false);

        pool.totalAsset.shares += uint128(shares);
        pool.totalAsset.amount += uint128(_amount);

        Deposited(_poolId, msg.sender, _amount);
    }

    function withdraw(uint256 _poolId) external {
        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        if (depositor.amount == 0) revert ZeroAmountForWithdraw();

        // calculate the available USDC amount for withdraw
        uint256 availableAmount = depositor.amount - depositor.lendingAmount;

        if (availableAmount == 0) revert NotAvailableAmountForWithdraw();

        depositor.amount -= availableAmount;

        uint256 shares = pool.totalAsset.toShares(availableAmount, false);
        pool.totalAsset.shares -= uint128(shares);
        pool.totalAsset.amount -= uint128(availableAmount);

        if (pool.isEtherLpToken) {
            payable(msg.sender).transfer(availableAmount);
        } else {
            usdcToken.approve(msg.sender, availableAmount);
            usdcToken.transfer(msg.sender, availableAmount);
        }

        Withdraw(_poolId, msg.sender);
    }

    function borrowToken(
        uint256 _poolId,
        uint256 _amount,
        uint256 _duration
    ) external payable {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][msg.sender];

        // check if borrower already rent
        if (loanData.collateralAmount > 0) revert AlreadyBorrowed();

        uint256 borrowableAmount;

        if (pool.isEtherLpToken) {
            // Borrower is going to borrow Ether
            if (usdcToken.balanceOf(msg.sender) < _amount)
                revert InsufficientCollateral();

            borrowableAmount = getEthUsdcPrice()
                .mul(_amount)
                .mul(pool.collateralFactor)
                .div(100);

            // check if there is sufficient the borrowable USDC amount in Vault.
            if (address(this).balance < borrowableAmount)
                revert InsufficientTokenInBalance();

            usdcToken.transferFrom(msg.sender, address(this), _amount);
            loanData.collateralAmount = _amount;
        } else {
            // Borrower is going to borrow USDC
            if (msg.value < _amount) revert InsufficientCollateral();

            borrowableAmount = getUsdcEthPrice()
                .mul(_amount)
                .mul(pool.collateralFactor)
                .div(100);

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
        loanData.repayAmount = calculateRepaymentAmount(
            _poolId,
            borrowableAmount,
            _duration
        );

        // calculate pool's earned reward from borrower's borrowing
        pool.earnedReward = calculateInterest(
            _poolId,
            borrowableAmount,
            _duration
        );

        // transfer Token to borrower
        if (pool.isEtherLpToken) {
            payable(msg.sender).transfer(borrowableAmount);
        } else {
            usdcToken.approve(msg.sender, borrowableAmount);
            usdcToken.transfer(msg.sender, borrowableAmount);
        }

        BorrowToken(msg.sender, _amount, borrowableAmount, _duration);
    }

    function repayLoan(uint256 _poolId, uint256 _amount) external payable {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][msg.sender];

        // check if borrower has an active loan
        if (loanData.repayAmount == 0) revert NotExistLoan();

        // check if repay amount is bigger than zero
        if (pool.isEtherLpToken) {
            if (_amount == 0 || msg.value != _amount) revert ZeroRepayAmount();
        } else {
            if (_amount == 0 || usdcToken.balanceOf(msg.sender) == 0)
                revert ZeroRepayAmount();
        }

        // If Borrow repays the amount bigger than the current repay amount, _amount should be loanData.repayAmount
        if (_amount >= loanData.repayAmount) _amount = loanData.repayAmount;

        if (!pool.isEtherLpToken) {
            // Borrower repays the borrowable token as USDC
            usdcToken.transferFrom(
                msg.sender,
                address(this),
                loanData.collateralAmount
            );
        }

        // update loan's repay amount
        loanData.repayAmount -= _amount;

        // If Borrower doesn't need to repay more, he can get his collateral
        if (loanData.repayAmount == 0) {
            delete loans[_poolId][msg.sender];

            if (pool.isEtherLpToken) {
                // Borrower receives the collateral as USDC token
                usdcToken.approve(msg.sender, loanData.collateralAmount);
                usdcToken.transfer(msg.sender, loanData.collateralAmount);
            } else {
                // Borrower receives the collateral as Ether
                payable(address(this)).transfer(loanData.collateralAmount);
            }
        }

        emit LoanRepaid(msg.sender, _amount);
    }

    function calculateInterest(
        uint256 _poolId,
        uint256 _loanAmount,
        uint256 _duration
    ) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];
        // Calculate interest charged on the loan
        uint256 yearlyInterest = (_loanAmount * pool.interestRate) / 100;
        uint256 dailyInterest = yearlyInterest / 365;
        uint256 totalInterest = dailyInterest * _duration;

        return totalInterest;
    }

    // Function to calculate total repayment amount including interest and fees
    function calculateRepaymentAmount(
        uint256 _poolId,
        uint256 _loanAmount,
        uint256 _duration
    ) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];
        // Calculate interest charged on the loan
        uint256 totalInterest = calculateInterest(
            _poolId,
            _loanAmount,
            _duration
        );

        // Calculate fees charged on the loan
        uint256 originationFees = (_loanAmount * pool.originalFeeRate) / 100;
        uint256 totalFees = originationFees;

        // Calculate total amount due including interest and fees
        uint256 totalRepayment = _loanAmount + totalInterest + totalFees;

        return totalRepayment;
    }

    function getEthUsdcPrice() public view returns (uint256) {
        (, int256 answer, , , ) = usdcEthPriceFeed.latestRoundData();

        // Convert the USDC/ETH price to a decimal value with 18 decimal places
        uint256 decimalUsdcEthPrice = uint256(answer) * 10 ** 10;
        return 10 ** 18 / decimalUsdcEthPrice;
    }

    function getUsdcEthPrice() public view returns (uint256) {
        (, int256 answer, , , ) = usdcEthPriceFeed.latestRoundData();

        // Convert the USDC/ETH price to a decimal value with 18 decimal places
        return uint256(answer) * 10 ** 10;
    }
}
