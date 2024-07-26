// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { Bagel, ISovereignPool, ALMLiquidityQuoteInput, ALMLiquidityQuote } from "src/Bagel.sol";
import { IValantisPool } from "valantis-core/pools/interfaces/IValantisPool.sol";

contract BagelTest is Test {

    Bagel bagel;

    IValantisPool pool;


    function setUp() public {
        pool = IValantisPool(makeAddr("POOL"));
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IValantisPool.token0.selector),
            abi.encode(makeAddr("ETH"))
        );

        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IValantisPool.token1.selector),
            abi.encode(makeAddr("DAI"))
        );

        bagel = new Bagel(address(pool));
    }

    function test_sandwich_failing() public {

        // sandwich a trade of swapping 10 eth for dai
        // first sandwich transaction will swap 100 eth for dai
        // second transaction will swap 10 eth for dai
        // third transaction will close sandwich by swapping received dai for eth

        ALMLiquidityQuoteInput memory input;
        input.isZeroToOne = true;
        input.amountInMinusFee = 100e18;
        // set initial reserves as 100 eth and 200_000 DAI


        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(ISovereignPool.getReserves.selector),
            abi.encode(100e18, 200_000e18)
        );        

        vm.prank(address(pool));
        // Sandwich start transaction
        ALMLiquidityQuote memory firstQuote = bagel.getLiquidityQuote(input, "", "");


        // Actual transaction
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(ISovereignPool.getReserves.selector),
            abi.encode(200e18, 200_000e18 - firstQuote.amountOut)
        ); 

        input.amountInMinusFee = 10e18;
        vm.prank(address(pool));
        ALMLiquidityQuote memory secondQuote = bagel.getLiquidityQuote(input, "", "");


        // Sandwich closing transaction
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(ISovereignPool.getReserves.selector),
            abi.encode(210e18, 200_000e18 - firstQuote.amountOut - secondQuote.amountOut)
        ); 

        input.isZeroToOne = false;
        input.amountInMinusFee = firstQuote.amountOut;
        vm.prank(address(pool));
        ALMLiquidityQuote memory thirdQuote = bagel.getLiquidityQuote(input, "", "");

        assert(100e18 - thirdQuote.amountOut > 0);
    }

}
