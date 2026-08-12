// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapFullAmount } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenIn, InvalidateTokenOut } from "../src/instructions/Invalidators.sol";

contract LimitSwapPartialFillTest is Test {
    using Math for uint256;

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e31);
        tokenB.mint(maker, 1e31);
        tokenA.mint(taker, 1e31);
        tokenB.mint(taker, 1e31);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // === LimitSwap ===

    function testFuzz_LimitSwap_ExactIn(uint256 balanceIn, uint256 balanceOut, uint256 amount, bool allowPartialFill) public view {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        amount = bound(amount, 1, balanceIn * 3);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));

        bool isPartialFill = amount > balanceIn;
        uint256 expectedIn = Math.min(amount, balanceIn);
        uint256 expectedOut = isPartialFill ? balanceOut : amount * balanceOut / balanceIn;

        (bool ok, bytes4 selector, uint256 amountIn, uint256 amountOut) = _tryQuote(order, amount, true, allowPartialFill);

        if (expectedOut == 0) {
            assertFalse(ok);
            assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
        } else if (isPartialFill && !allowPartialFill) {
            assertFalse(ok, "Partial fill should be rejected without the flag");
            assertEq(selector, TakerTraitsLib.TakerTraitsTakerAmountInMismatch.selector);
        } else {
            assertTrue(ok);
            assertEq(amountIn, expectedIn, "Input should fill up to balanceIn");
            assertEq(amountOut, expectedOut);

            // Rounding favors maker at every fill
            assertGe(amountIn * balanceOut, amountOut * balanceIn, "Rate should favor maker");
        }
    }

    function testFuzz_LimitSwap_ExactOut(uint256 balanceIn, uint256 balanceOut, uint256 amount, bool allowPartialFill) public view {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        amount = bound(amount, 1, balanceOut * 3);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));

        bool isPartialFill = amount > balanceOut;
        uint256 expectedOut = Math.min(amount, balanceOut);
        uint256 expectedIn = (expectedOut * balanceIn).ceilDiv(balanceOut);

        (bool ok, bytes4 selector, uint256 amountIn, uint256 amountOut) = _tryQuote(order, amount, false, allowPartialFill);

        if (isPartialFill && !allowPartialFill) {
            assertFalse(ok, "Partial fill should be rejected without the flag");
            assertEq(selector, TakerTraitsLib.TakerTraitsTakerAmountOutMismatch.selector);
        } else {
            assertTrue(ok);
            assertEq(amountOut, expectedOut, "Output should fill up to balanceOut");
            assertEq(amountIn, expectedIn);

            // Rounding favors maker at every fill, tight to 1 wei
            assertGe(amountIn * balanceOut, amountOut * balanceIn, "Rate should favor maker");
            assertLt((amountIn - 1) * balanceOut, amountOut * balanceIn, "One wei less input would favor taker");
        }
    }

    function testFuzz_LimitSwapFullAmount(uint256 balanceIn, uint256 balanceOut, uint256 amount, bool isExactIn) public view {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        uint256 balance = isExactIn ? balanceIn : balanceOut;
        amount = bound(amount, 1, balance * 3);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            LimitSwapFullAmount.build(address(tokenA), address(tokenB))
        ));

        (bool ok, bytes4 selector, uint256 amountIn, uint256 amountOut) = _tryQuote(order, amount, isExactIn, true);

        if (amount < balance) {
            assertFalse(ok, "Amount below balance should not cover the full-amount order");
            assertEq(selector, LimitSwapFullAmount.LimitSwapAmountShouldCoverBalance.selector);
        } else {
            assertTrue(ok);
            assertEq(amountIn, balanceIn, "Fills exactly balanceIn");
            assertEq(amountOut, balanceOut, "Fills exactly balanceOut");
        }
    }

    // === Multifill ===

    function testFuzz_Multifill_InvalidateTokenIn(uint256 balanceIn, uint256 balanceOut, uint256[4] memory asks) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            InvalidateTokenIn.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory takerData = _makeTakerData(order, true, true);

        uint256 makerBalanceA = tokenA.balanceOf(maker);
        uint256 takerBalanceB = tokenB.balanceOf(taker);

        uint256 filled;
        uint256 totalOut;
        for (uint256 i = 0; i < asks.length; i++) {
            uint256 remaining = balanceIn - filled;
            if (remaining == 0) break;

            uint256 ask = bound(asks[i], 1, balanceIn);
            uint256 expectedIn = Math.min(ask, remaining);
            uint256 scaledOut = balanceOut * remaining / balanceIn;
            uint256 expectedOut = expectedIn * scaledOut / remaining;

            try swapVM.swap(order, ask, takerData) returns (uint256 amountIn, uint256 amountOut, bytes32) {
                assertEq(amountIn, expectedIn, "Fill should consume ask capped by remaining capacity");
                assertEq(amountOut, expectedOut);

                // Rate is constant-approx across fills: drift is maker-side and below 2 wei of tokenOut per fill
                assertGe(amountIn * balanceOut, amountOut * balanceIn, "Rate should favor maker");
                assertLe(amountIn * balanceOut, amountOut * balanceIn + 2 * balanceIn, "Rate drifts too far from the order rate");

                filled += amountIn;
                totalOut += amountOut;
            } catch (bytes memory reason) {
                // Only dust fills quoting to zero output may revert
                assertEq(bytes4(reason), TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
                assertEq(expectedOut, 0);
            }
        }

        assertLe(filled, balanceIn, "Cumulative input is bounded by the order capacity");
        assertLe(totalOut, balanceOut, "Cumulative output is bounded by the order capacity");

        // Storage and token accounting match the fills
        assertEq(swapVM.tokenInInvalidators(maker, swapVM.hash(order), address(tokenA)), filled);
        assertEq(tokenA.balanceOf(maker) - makerBalanceA, filled);
        assertEq(tokenB.balanceOf(taker) - takerBalanceB, totalOut);
    }

    function testFuzz_Multifill_InvalidateTokenOut(uint256 balanceIn, uint256 balanceOut, uint256[4] memory asks) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            InvalidateTokenOut.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory takerData = _makeTakerData(order, false, true);

        uint256 makerBalanceA = tokenA.balanceOf(maker);
        uint256 takerBalanceB = tokenB.balanceOf(taker);

        uint256 filled;
        uint256 totalIn;
        for (uint256 i = 0; i < asks.length; i++) {
            uint256 remaining = balanceOut - filled;
            if (remaining == 0) break;

            uint256 ask = bound(asks[i], 1, balanceOut);
            uint256 expectedOut = Math.min(ask, remaining);
            uint256 scaledIn = (balanceIn * remaining).ceilDiv(balanceOut);
            uint256 expectedIn = (expectedOut * scaledIn).ceilDiv(remaining);

            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, ask, takerData);

            assertEq(amountOut, expectedOut, "Fill should consume ask capped by remaining capacity");
            assertEq(amountIn, expectedIn);

            // Rate is constant-approx across fills: drift is maker-side and below 2 wei of tokenIn per fill
            assertGe(amountIn * balanceOut, amountOut * balanceIn, "Rate should favor maker");
            assertLe(amountIn * balanceOut, amountOut * balanceIn + 2 * balanceOut, "Rate drifts too far from the order rate");

            filled += amountOut;
            totalIn += amountIn;
        }

        assertLe(filled, balanceOut, "Cumulative output is bounded by the order capacity");

        // Storage and token accounting match the fills
        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), filled);
        assertEq(tokenA.balanceOf(maker) - makerBalanceA, totalIn);
        assertEq(tokenB.balanceOf(taker) - takerBalanceB, filled);
    }

    function testFuzz_FullFill_InvalidateTokenIn_ConsumesAtMostBalanceOut(uint256 balanceIn, uint256 balanceOut, uint256[3] memory asks) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            InvalidateTokenIn.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory takerData = _makeTakerData(order, true, true);

        uint256 filled;
        uint256 totalOut;
        // Random partial fills, then drain the remainder with an over-ask
        for (uint256 i = 0; i <= asks.length; i++) {
            uint256 remaining = balanceIn - filled;
            if (remaining == 0) break;

            uint256 ask = i < asks.length ? bound(asks[i], 1, balanceIn) : balanceIn;
            try swapVM.swap(order, ask, takerData) returns (uint256 amountIn, uint256 amountOut, bytes32) {
                filled += amountIn;
                totalOut += amountOut;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
                // Remainder quotes to zero output: the order cannot be filled to the end
                if (i == asks.length) return;
            }
        }

        // Fully filled order consumes at most the declared balanceOut: cumulative rate drift favors maker
        assertEq(filled, balanceIn, "Order should be fully filled");
        assertLe(totalOut, balanceOut, "Full fill should consume at most balanceOut");
    }

    function testFuzz_FullFill_InvalidateTokenOut_PaysAtLeastBalanceIn(uint256 balanceIn, uint256 balanceOut, uint256[3] memory asks) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            InvalidateTokenOut.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory takerData = _makeTakerData(order, false, true);

        uint256 filled;
        uint256 totalIn;
        // Random partial fills, then drain the remainder with an over-ask
        for (uint256 i = 0; i <= asks.length; i++) {
            uint256 remaining = balanceOut - filled;
            if (remaining == 0) break;

            uint256 ask = i < asks.length ? bound(asks[i], 1, balanceOut) : balanceOut;
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, ask, takerData);
            filled += amountOut;
            totalIn += amountIn;
        }

        // Fully filled order pays the maker at least the declared balanceIn: cumulative rate drift favors maker
        assertEq(filled, balanceOut, "Order should be fully filled");
        assertGe(totalIn, balanceIn, "Full fill should pay at least balanceIn");
    }

    function test_ExhaustedOrder_RevertsCleanly() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            InvalidateTokenIn.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));

        bytes memory exactInData = _makeTakerData(order, true, true);
        bytes memory exactOutData = _makeTakerData(order, false, true);

        // Exhaust the order in one full fill
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactInData);
        assertEq(amountIn, 100e18);
        assertEq(amountOut, 200e18);

        // Both directions revert cleanly, not with a panic
        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        swapVM.swap(order, 1e18, exactInData);

        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        swapVM.swap(order, 1e18, exactOutData);
    }

    // === Helpers ===

    function _tryQuote(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn,
        bool allowPartialFill
    ) internal view returns (bool ok, bytes4 selector, uint256 amountIn, uint256 amountOut) {
        try swapVM.asView().quote(order, amount, _makeTakerData(order, isExactIn, allowPartialFill)) returns (uint256 quotedIn, uint256 quotedOut, bytes32) {
            return (true, bytes4(0), quotedIn, quotedOut);
        } catch (bytes memory reason) {
            return (false, bytes4(reason), 0, 0);
        }
    }

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn, bool allowPartialFill) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: allowPartialFill,
            threshold: "",
            to: address(this),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
