// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

import {Utils} from "./utils/Util.sol";
import {IUniswapRouter} from "./interfaces/IUniswap.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BaseSetup is Test {
    address internal constant USDC_ADDRESS =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant UNISWAP_ROUTER_ADDRESS =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant WETH_ADDRESS =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Skip forward block.timestamp for 3 days.
    uint256 internal constant SKIP_FORWARD_PERIOD = 3600 * 24 * 3;
    uint256 internal constant USDC_DECIMAL = 1e6;
    uint256 internal constant ETHER_DECIMAL = 1e18;

    address[] internal pathUSDC;

    Utils internal utils;

    address payable[] internal users;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal david;
    address internal edward;
    address internal fraig;

    IERC20 internal usdc;
    IWETH internal weth;

    IUniswapRouter internal uniswapRouter;

    function setUp() public virtual {
        utils = new Utils();
        users = utils.createUsers(6);

        alice = users[0];
        vm.label(alice, "Alice");

        bob = users[1];
        vm.label(bob, "Bob");

        carol = users[2];
        vm.label(carol, "Carol");

        david = users[3];
        vm.label(david, "David");

        edward = users[4];
        vm.label(edward, "Edward");

        fraig = users[5];
        vm.label(fraig, "Fraig");

        initPathForSwap();
        getStableCoinBalanceForTesting();
    }

    function initPathForSwap() internal {
        usdc = IERC20(USDC_ADDRESS);
        weth = IWETH(WETH_ADDRESS);

        pathUSDC = new address[](2);
        pathUSDC[0] = WETH_ADDRESS;
        pathUSDC[1] = USDC_ADDRESS;
    }

    function swapETHToToken(
        address[] memory _path,
        address _to,
        uint256 _amount
    ) internal {
        uint256 deadline = block.timestamp + 3600000;

        uniswapRouter.swapExactETHForTokens{value: _amount}(
            0,
            _path,
            _to,
            deadline
        );
    }

    function getStableCoinBalanceForTesting() internal {
        uint wethAmount = 50 * 1e18;

        uniswapRouter = IUniswapRouter(UNISWAP_ROUTER_ADDRESS);

        weth.approve(UNISWAP_ROUTER_ADDRESS, wethAmount * 10);

        swapETHToToken(pathUSDC, address(alice), wethAmount);
        swapETHToToken(pathUSDC, address(bob), wethAmount);
        swapETHToToken(pathUSDC, address(carol), wethAmount);
        swapETHToToken(pathUSDC, address(david), wethAmount);
        swapETHToToken(pathUSDC, address(fraig), wethAmount);

        console.log(
            "Alice's usdc balance = %d",
            usdc.balanceOf(address(alice))
        );
        console.log("Bob's usdc balance = %d", usdc.balanceOf(address(bob)));
        console.log(
            "Carol's usdc balance = %d",
            usdc.balanceOf(address(carol))
        );
        console.log(
            "David's usdc balance = %d",
            usdc.balanceOf(address(david))
        );
        console.log(
            "Edward's usdc balance = %d",
            usdc.balanceOf(address(edward))
        );
    }
}
