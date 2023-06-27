// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract LendingVault is Ownable {
    using SafeMath for uint256;

    address public constant AGGREGATOR_USDC_ETH =
        0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    address public constant WETH_ADDRESS =
        0xa463a1eF5Ba7944186cE1FDf795707E21D5D44eE;
    address public constant USDC_ADDRESS =
        0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    struct Pool {
        IERC20 collateralToken;
        IERC20 borrowToken;
        IERC20 lpToken;
        uint256 depositTokenAmount;
        // Daily interest rate
        uint256 interestRate;
        // Fee for borrower
        uint256 originalFeeRate;
        // Collateral factor

        uint256 collateralFactor;
        uint256 earnedReward;
        bool isLpTokenETH;
        uint256 lastRewardedBlock;
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

    Pool[] public pools;
    mapping(uint256 => mapping(address => Loan)) loans;
    mapping(uint256 => mapping(address => Depositor)) public depositors;

    AggregatorV3Interface internal usdcEthPriceFeed;

    event DepositMade(address indexed depositor, uint256 amount);
    event LoanTaken(
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

    constructor() {
        usdcEthPriceFeed = AggregatorV3Interface(AGGREGATOR_USDC_ETH);
    }

    /**
     * @dev Create a new staking pool
     */
    function createPool(
        IERC20 _lpToken,
        IERC20 _collateralToken,
        uint8 _interestRate,
        uint8 _collateralFactor,
        uint8 _originalFeeRate
    ) external onlyOwner {
        Pool memory pool;

        pool.collateralToken = _collateralToken;
        pool.borrowToken = _lpToken;
        pool.lpToken = _lpToken;
        pool.interestRate = _interestRate;
        pool.collateralFactor = _collateralFactor;
        pool.originalFeeRate = _originalFeeRate;

        pools.push(pool);

        // uint256 poolId = pools.length - 1;
        // emit PoolCreated(poolId);
    }

    function deposit(uint256 _poolId, uint256 _amount) external {
        if (_amount == 0) revert("Deposit amount should be bigger than zero.");

        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        if (pool.lpToken.balanceOf(msg.sender) < _amount)
            revert("Insufficient LP Token balance");

        pool.lpToken.transferFrom(msg.sender, address(this), _amount);

        depositor.amount += _amount;
        pool.depositTokenAmount += _amount;
    }

    function withdraw(uint256 _poolId) external {
        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        uint256 amount = depositor.amount;

        if (amount == 0) revert("Withdraw amount can't be zero");

        // get the available USDC amount for withdraw
        uint256 availableAmount = depositor.amount - depositor.lendingAmount;
        depositor.amount -= availableAmount;
        pool.depositTokenAmount -= availableAmount;

        pool.lpToken.approve(msg.sender, availableAmount);
        pool.lpToken.transfer(msg.sender, availableAmount);
    }

    function borrowToken(
        uint256 _poolId,
        uint256 _amount,
        uint256 _duration
    ) external {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][msg.sender];

        // check if borrower already rent
        if (loanData.collateralAmount > 0)
            revert("Borrower can only have one active loan at a time");

        if (pool.collateralToken.balanceOf(msg.sender) < _amount)
            revert("Insufficient collateral");

        uint256 borrowableAmount;

        // get the borrowable amount from the collateral amount
        if (pool.isLpTokenETH)
            borrowableAmount = getEthUsdcPrice()
                .mul(_amount)
                .mul(pool.collateralFactor)
                .div(100);
        else
            borrowableAmount = getUsdcEthPrice()
                .mul(_amount)
                .mul(pool.collateralFactor)
                .div(100);

        // check if there is sufficient the borrowable USDC amount in Vault.
        if (pool.borrowToken.balanceOf(address(this)) < borrowableAmount)
            revert("Insufficient Borrow token balance");

        pool.collateralToken.transferFrom(msg.sender, address(this), _amount);

        loanData.collateralAmount = _amount;
        loanData.borrowedAmount = borrowableAmount;
        loanData.timestamp = block.timestamp;
        loanData.duration = _duration;
        // calculate repayment amount
        loanData.repayAmount = calculateRepaymentAmount(
            _poolId,
            borrowableAmount,
            _duration
        );

        pool.earnedReward = calculateInterest(
            _poolId,
            borrowableAmount,
            _duration
        );

        pool.borrowToken.approve(msg.sender, borrowableAmount);
        pool.borrowToken.transfer(msg.sender, borrowableAmount);
    }

    function repayLoan(uint256 _poolId, uint256 _amount) external {
        Pool storage pool = pools[_poolId];
        Loan storage loanData = loans[_poolId][msg.sender];

        // check if repay amount is bigger than zero
        if (_amount == 0) revert("amount should be bigger than zero.");

        // check if borrower has an active loan
        if (loanData.repayAmount <= 0)
            revert("Borrower does not have an active loan");

        if (
            loanData.collateralAmount > 0 &&
            pool.borrowToken.balanceOf(msg.sender) < _amount
        ) revert("Borrower doesn't have sufficient token balance for repay");

        if (_amount >= loanData.repayAmount) {
            // repay the borrowable token
            pool.borrowToken.transferFrom(
                msg.sender,
                address(this),
                loanData.repayAmount
            );
            // receive the collateral
            pool.collateralToken.transfer(
                msg.sender,
                loanData.collateralAmount
            );

            delete loans[_poolId][msg.sender];

            emit LoanRepaid(msg.sender, loanData.repayAmount);
        } else {
            pool.borrowToken.transferFrom(msg.sender, address(this), _amount);

            // Partially repay the loan
            loanData.repayAmount -= _amount;

            if (loanData.repayAmount <= 0) {
                pool.collateralToken.transfer(msg.sender, _amount);
                delete loans[_poolId][msg.sender];
            }

            emit LoanRepaid(msg.sender, _amount);
        }
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
