pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";

contract LendingVault is ChainlinkClient {
    struct Currency {
        IERC20 token;
        bytes32 jobId;
        uint256 fee;
        uint256 price;
    }

    Currency[] public currencies;
    IERC20 public vaultToken;

    mapping(address => mapping(uint256 => uint256)) public balances;

    constructor(IERC20 _vaultToken, Currency[] memory _currencies) {
        vaultToken = _vaultToken;
        currencies = _currencies;
        setPublicChainlinkToken();

        for (uint256 i = 0; i < currencies.length; i++) {
            Currency storage currency = currencies[i];
            requestPrice(currency.jobId, currency.fee);
        }
    }

    function deposit(uint256 amount, uint256 currencyIndex) external {
        getPrice(currencyIndex);
        Currency storage currency = currencies[currencyIndex];
        currency.token.transferFrom(msg.sender, address(this), amount);
        uint256 shares = calculateShares(amount, currency.price);
        balances[msg.sender][currencyIndex] += shares;
        vaultToken.transfer(msg.sender, shares);
    }

    function withdraw(uint256 shares, uint256 currencyIndex) external {
        getPrice(currencyIndex);
        Currency storage currency = currencies[currencyIndex];
        uint256 amount = calculateAmount(shares, currency.price);
        balances[msg.sender][currencyIndex] -= shares;
        vaultToken.transferFrom(msg.sender, address(this), shares);
        currency.token.transfer(msg.sender, amount);
    }

    function calculateShares(
        uint256 amount,
        uint256 price
    ) public view returns (uint256) {
        uint256 totalSupply = vaultToken.totalSupply();
        if (totalSupply == 0) {
            return amount;
        } else {
            uint256 underlyingBalance = getUnderlyingBalance();
            return (amount * price * totalSupply) / underlyingBalance;
        }
    }

    function calculateAmount(
        uint256 shares,
        uint256 price
    ) public view returns (uint256) {
        uint256 totalSupply = vaultToken.totalSupply();
        uint256 underlyingBalance = getUnderlyingBalance();
        return (shares * underlyingBalance) / (price * totalSupply);
    }

    function getUnderlyingBalance() public view returns (uint256) {
        uint256 underlyingBalance = 0;
        for (uint256 i = 0; i < currencies.length; i++) {
            Currency storage currency = currencies[i];
            uint256 balance = currency.token.balanceOf(address(this));
            underlyingBalance += balance * currency.price;
        }
        return underlyingBalance;
    }

    function requestPrice(bytes32 jobId, uint256 fee) public {
        Chainlink.Request memory request = buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfill.selector
        );
        request.add(
            "get",
            "https://api.chain.link/v1/crypto/price?fsym=ETH&tsyms=USDC"
        );
        request.add("path", "USDC");
        request.addInt("times", 100);
        sendChainlinkRequestTo(oracleAddress(), request, fee);
    }

    function getPrice(uint256 currencyIndex) public {
        Currency storage currency = currencies[currencyIndex];
        requestPrice(currency.jobId, currency.fee);
    }

    function fulfill(
        bytes32 requestId,
        uint256 price
    ) public recordChainlinkFulfillment(requestId) {
        for (uint256 i = 0; i < currencies.length; i++) {
            Currency storage currency = currencies[i];
            if (requestId == currency.jobId) {
                currency.price = price;
                break;
            }
        }
    }
}

contract ERC4626Token is IERC20 {
    string public name = "Vault Token";
    string public symbol = "VT";
    uint8 public decimals = 18;

    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        require(msg.sender == address(this), "Only the vault can mint tokens");
        balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) external override returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        balances[from] -= amount;
        allowances[from][msg.sender] -= amount;
        balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function balanceOf(
        address account
    ) external view override returns (uint256) {
        return balances[account];
    }

    function allowance(
        address owner,
        address spender
    ) external view override returns (uint256) {
        return allowances[owner][spender];
    }
}
