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

    /**
    @dev Allows a user to deposit tokens into a pool by providing the pool ID and the amount of tokens to deposit.
    @param _poolId The ID of the pool into which the user wants to deposit tokens.
    @param _amount The amount of tokens the user wants to deposit.
    @notice This function checks if the amount of tokens to deposit is not zero. If the amount of tokens to deposit is not zero, the function calculates the asset amount based on the total liquidity of the pool and the amount of tokens deposited.
            If the pool uses Ether as collateral, the function checks if the transfer Ether amount is not zero and if the transfer Ether amount is less than the amount of tokens to deposit. If the transfer Ether amount is less than the amount of tokens to deposit, the function sets the amount of tokens to deposit to the transfer Ether amount.
            If the pool uses USDC as collateral, the function checks if the user has sufficient balance for deposit and transfers the USDC from the user to the vault contract.
            The function then updates the depositor's asset amount and the pool's data and emits a Deposited event.
    */
    function deposit(
        uint32 _poolId,
        uint256 _amount
    ) external payable noReentrant {
        if (_amount == 0) revert ZeroAmountForDeposit();

        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        uint256 assetAmount;

        if (pool.isEtherLpToken) {
            // check if transfer Ether is not zero
            if (msg.value == 0) revert ZeroAmountForDeposit();

            // check if transfer Ether amount is less than _amount, _amount should be msg.value
            if (msg.value != _amount) _amount = msg.value;

            // calculate asset amount based on total liquidity
            assetAmount = calculateAssetAmount(_poolId, _amount);
        } else {
            // check if user has sufficient balance for deposit
            if (usdcToken.balanceOf(msg.sender) < _amount)
                revert InsufficientBalanceForDeposit();

            // calculate asset amount based on total liquidity
            assetAmount = calculateAssetAmount(_poolId, _amount);

            // transfer USDC from user to vault contract
            usdcToken.transferFrom(msg.sender, address(this), _amount);
        }

        // update depositor's asset amount
        depositor.assetAmount += assetAmount;

        // pool's deposit amount
        pool.currentAmount += _amount;
        // pool's total amount
        pool.totalAssetAmount += assetAmount;

        emit Deposited(_poolId, msg.sender, _amount);
    }

    /**
    @dev Allows a user to withdraw tokens from a pool by providing the pool ID.
    @param _poolId The ID of the pool from which the user wants to withdraw tokens.
    @notice This function checks if the user has sufficient withdraw amount. If the user has sufficient withdraw amount, the function calculates the amount the user can withdraw based on the pool's current liquidity amount and the user's asset amount.
            The function then updates the depositor's asset amount and the pool's data and transfers the withdrawn tokens to the user.
            If the pool uses Ether as collateral, the function transfers Ether to the user. If the pool uses USDC as collateral, the function approves the transfer of USDC to the user and then transfers the USDC to the user.
    */
    function withdraw(uint32 _poolId) external noReentrant {
        Pool storage pool = pools[_poolId];
        Depositor storage depositor = depositors[_poolId][msg.sender];

        uint256 assetAmount = depositor.assetAmount;

        // check if User has sufficient withdraw amount
        if (assetAmount == 0) revert ZeroAmountForWithdraw();

        // calculate amount user can withdraw
        uint256 amount = calculateAmount(_poolId, assetAmount);

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

    /**
    @dev Allows a user to borrow tokens from a pool by providing collateral and specifying the duration of the loan.
    @param _poolId The ID of the pool from which the user wants to borrow tokens.
    @param _amount The amount of collateral the user wants to provide for the loan.
    @param _duration The duration of the loan in days.
    @return A tuple containing the amount of tokens borrowed and the amount to be repaid.
    @notice This function checks if the borrower has already borrowed tokens from the pool and reverts if they have.
            It then calculates the amount of tokens the borrower can borrow based on the collateral provided and the pool's collateral factor.
            If the pool uses Ether as collateral, the function checks if the borrower has provided enough Ether to borrow the requested amount of tokens.
            If the pool uses USDC as collateral, the function checks if the borrower has provided enough USDC to borrow the requested amount of tokens.
            The function then calculates the repayment amount based on the borrowed amount and the loan duration.
            Finally, the function updates the borrower's loan data and the pool's data and transfers the borrowed tokens to the borrower.
    */
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

        return (borrowableAmount, repayAmount);
    }

    /**
    @dev Allows a user to repay a loan by providing the pool ID and the amount of tokens to repay.
    @param _poolId The ID of the pool from which the user wants to repay the loan.
    @param _amount The amount of tokens the user wants to repay.
    @notice This function checks if the borrower has an active loan. If the borrower has an active loan, the function checks if the repay amount is bigger than zero.
            If the pool uses Ether as collateral, the function checks if the transfer Ether amount is not zero and sets the amount of tokens to repay to the transfer Ether amount.
            If the pool uses USDC as collateral, the function checks if the user has sufficient balance for repayment and transfers the USDC from the user to the vault contract.
            The function then updates the loan's repay amount, the pool's data, and emits a LoanRepaid event.
            If the borrower doesn't need to repay more, the function updates the loan data and transfers the borrower's collateral back to the borrower.
    */
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
            // update loan's interest amount
            loanData.interestAmount = 0;
            // update loan's fee amount
            loanData.feeAmount = 0;
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

    /**
    @dev Allows a user to liquidate a loan by providing the pool ID and the borrower's address.
    @param _poolId The ID of the pool from which the user wants to liquidate the loan.
    @param _account The address of the borrower whose loan is being liquidated.
    @notice This function checks if the caller is not the loan owner and if the loan has collateral and is at liquidate state.
            If the pool uses Ether as collateral, the function checks if the caller has sufficient balance for liquidation and transfers the USDC with a discount percent to the caller.
            If the pool uses USDC as collateral, the function checks if the user has sufficient balance for liquidation and transfers the USDC from the user to the vault contract.
            The function then updates the pool's data and the loan data and returns the collateral amount to the caller.
    */
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

    /**
    @dev Calculates the amount of tokens to pay for liquidating a loan by providing the pool ID and the borrower's address.
    @param _poolId The ID of the pool from which the user wants to liquidate the loan.
    @param _account The address of the borrower whose loan is being liquidated.
    @return The amount of tokens to pay for liquidating the loan.
    @notice This function retrieves the pool and loan data based on the pool ID and the borrower's address.
            If the pool uses Ether as collateral, the function calculates the amount of USDC to pay for liquidating the loan based on the collateral amount, the USDC/ETH price, and the discount rate.
            If the pool uses USDC as collateral, the function calculates the amount of USDC to pay for liquidating the loan based on the collateral amount and the discount rate.
    */
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

    /**
    @dev Returns the amount of tokens to repay for the loan of the caller by providing the pool ID.
    @param _poolId The ID of the pool from which the caller wants to get the amount of tokens to repay for the loan.
    @return The amount of tokens to repay for the loan of the caller.
    @notice This function retrieves the loan data of the caller based on the pool ID and returns the amount of tokens to repay for the loan.
    */
    function getRepayAmount(uint32 _poolId) public view returns (uint256) {
        Loan memory loanData = loans[_poolId][msg.sender];
        return loanData.repayAmount;
    }

    /**
    @dev Returns the total liquidity of a pool by providing the pool ID.
    @param _poolId The ID of the pool from which the caller wants to get the total liquidity.
    @return The total liquidity of the pool.
    @notice This function retrieves the pool data based on the pool ID and calculates the total liquidity of the pool by adding the total borrow amount and the current amount and subtracting the total reserve amount.
    */
    function getTotalLiquidity(uint32 _poolId) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];
        return
            pool.totalBorrowAmount.add(pool.currentAmount).sub(
                pool.totalReserveAmount
            );
    }

    /**
    @dev Returns the current USDC/ETH price from the Chainlink price feed.
    @return The current USDC/ETH price with 18 decimal places.
    @notice This function retrieves the latest round data from the Chainlink price feed for the USDC/ETH pair and returns the price with 18 decimal places.
            According to the documentation, the return value is a fixed point number with 18 decimals for ETH data feeds
    */
    function getUsdcEthPrice() internal view returns (uint256) {
        (, int256 answer, , , ) = usdcEthPriceFeed.latestRoundData();
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

        // Calculate fees charged on the loan
        uint256 reserveFees = (_loanAmount * pool.reserveFeeRate) / 100;
        uint256 feeAmount = reserveFees;

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

    /**
    @dev Calculates the amount of tokens to deposit or withdraw based on the asset amount and the total liquidity of a pool by providing the pool ID.
    @param _poolId The ID of the pool from which the caller wants to calculate the amount of tokens to deposit or withdraw.
    @param _assetAmount The amount of asset tokens the caller wants to deposit or withdraw.
    @return The amount of tokens to deposit or withdraw based on the asset amount and the total liquidity of the pool.
    @notice This function retrieves the pool data based on the pool ID and calculates the amount of tokens to deposit or withdraw based on the asset amount and the total liquidity of the pool.
    */
    function calculateAmount(
        uint32 _poolId,
        uint256 _assetAmount
    ) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];

        uint256 totalLiquidityAmount = getTotalLiquidity(_poolId);

        uint256 amount = _assetAmount.mul(totalLiquidityAmount).divCeil(
            pool.totalAssetAmount
        );

        return amount;
    }

    /**
    @dev Calculates the asset amount based on the pool ID and the amount.
    @param _poolId The ID of the pool.
    @param _amount The amount to calculate the asset amount for.
    @return The calculated asset amount.
    */
    function calculateAssetAmount(
        uint32 _poolId,
        uint256 _amount
    ) internal view returns (uint256) {
        Pool memory pool = pools[_poolId];

        uint256 totalLiquidityAmount = getTotalLiquidity(_poolId);

        if (pool.totalAssetAmount == 0 || totalLiquidityAmount == 0)
            return _amount;

        uint256 assetAmount = _amount.mul(pool.totalAssetAmount).div(
            totalLiquidityAmount
        );

        return assetAmount;
    }

    /**
    @dev Calculates the total interest charged on a loan based on the loan amount, interest rate, and duration.
    @param _loanAmount The amount of the loan.
    @param _interestRate The interest rate charged on the loan.
    @param _duration The duration of the loan.
    @return The total interest charged on the loan.
    */
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
