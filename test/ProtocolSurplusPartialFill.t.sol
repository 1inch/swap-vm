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
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenIn, InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";
import { FeeBuilders } from "./utils/FeeBuilders.sol";

contract ProtocolSurplusPartialFillTest is Test {
    using Math for uint256;

    uint256 constant BPS = 1e7;

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient = makeAddr("feeRecipient");

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

    /// @dev Order: 100e18 in -> 200e18 out, maker estimates 80e18 total input, 10% surplus fee.
    ///   Each fill of half the order must contribute half the estimate: surplus 10e18, fee 1e18 per fill,
    ///   regardless of being the first or the second fill and of over-asking.
    function test_SurplusIn_Multifill_ProRataEstimate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeBuilders.protocolSurplusIn(0.1e7, feeRecipient, 80e18),
            InvalidateTokenIn.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactInData = _makeTakerData(order, true);

        // First fill: half the order
        uint256 recipientBefore = tokenA.balanceOf(feeRecipient);
        uint256 makerBefore = tokenA.balanceOf(maker);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 50e18, exactInData);

        assertEq(amountIn, 50e18);
        assertEq(amountOut, 100e18);
        // estimate share 40e18, realIn 50e18 -> surplus 10e18, fee 1e18
        assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, 1e18, "First fill surplus fee");
        assertEq(tokenA.balanceOf(maker) - makerBefore, 49e18, "Maker receives input minus surplus fee");

        // Second fill: over-ask partially fills the remaining half, same pro-rata surplus
        recipientBefore = tokenA.balanceOf(feeRecipient);
        makerBefore = tokenA.balanceOf(maker);
        (amountIn, amountOut,) = swapVM.swap(order, 80e18, exactInData);

        assertEq(amountIn, 50e18, "Over-ask should partially fill the remainder");
        assertEq(amountOut, 100e18);
        assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, 1e18, "Second fill surplus fee should stay pro-rata");
        assertEq(tokenA.balanceOf(maker) - makerBefore, 49e18, "Maker receives input minus surplus fee");

        assertEq(swapVM.tokenInInvalidators(maker, swapVM.hash(order), address(tokenA)), 100e18);
    }

    /// @dev Order: 100e18 in -> 200e18 out, maker estimates 240e18 total output, 10% surplus fee.
    ///   Each fill of half the order compares against half the estimate: surplus 20e18, fee 2e18 per fill.
    function test_SurplusOut_Multifill_ProRataEstimate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            FeeBuilders.protocolSurplusOut(0.1e7, feeRecipient, 240e18),
            InvalidateTokenOut.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactOutData = _makeTakerData(order, false);

        // First fill: half the order
        uint256 recipientBefore = tokenB.balanceOf(feeRecipient);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactOutData);

        assertEq(amountOut, 100e18);
        assertEq(amountIn, 50e18);
        // estimate share 120e18, realOut 100e18 -> surplus 20e18, fee 2e18 paid by maker
        assertEq(tokenB.balanceOf(feeRecipient) - recipientBefore, 2e18, "First fill surplus fee");

        // Second fill: over-ask partially fills the remaining half, same pro-rata surplus
        recipientBefore = tokenB.balanceOf(feeRecipient);
        (amountIn, amountOut,) = swapVM.swap(order, 150e18, exactOutData);

        assertEq(amountOut, 100e18, "Over-ask should partially fill the remainder");
        assertEq(amountIn, 50e18);
        assertEq(tokenB.balanceOf(feeRecipient) - recipientBefore, 2e18, "Second fill surplus fee should stay pro-rata");

        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), 200e18);
    }

    function testFuzz_SurplusIn_Multifill(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 estimate,
        uint24 feeBps,
        uint24 surplusBps,
        uint256[3] memory asks
    ) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        estimate = bound(estimate, 0, 1e30);
        feeBps = uint24(bound(feeBps, 0, BPS - 1));
        surplusBps = uint24(bound(surplusBps, 1, BPS - 1));

        ISwapVM.Order memory order = _flatSurplusOrder(true, balanceIn, balanceOut, feeBps, surplusBps, estimate);
        bytes memory exactInData = _makeTakerData(order, true);

        uint256 filled;
        uint256 totalShares;
        for (uint256 i = 0; i < asks.length; i++) {
            uint256 remaining = balanceIn - filled;
            if (remaining == 0) break;

            uint256 ask = bound(asks[i], 1, balanceIn);
            uint256 expectedNet = Math.min(ask - ask * feeBps / BPS, remaining);
            uint256 expectedOut = expectedNet * (balanceOut * remaining / balanceIn) / remaining;
            uint256 expectedFlat = expectedNet == ask - ask * feeBps / BPS
                ? ask * feeBps / BPS
                : expectedNet * feeBps / (BPS - feeBps);

            // Estimate share is pro-rata of the whole order by this fill's output
            uint256 share = (estimate * expectedOut).ceilDiv(balanceOut);
            uint256 expectedFee = expectedFlat + (expectedNet > share ? expectedNet - share : 0) * surplusBps / BPS;

            uint256 recipientBefore = tokenA.balanceOf(feeRecipient);
            try swapVM.swap(order, ask, exactInData) returns (uint256 amountIn, uint256 amountOut, bytes32) {
                assertEq(amountIn, expectedNet + expectedFlat);
                assertEq(amountOut, expectedOut);
                assertEq(tokenA.balanceOf(feeRecipient) - recipientBefore, expectedFee, "Flat and surplus fees should be counted against the real fill");

                filled += expectedNet;
                totalShares += share;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
                assertEq(expectedOut, 0);
            }
        }

        // Estimate shares across all fills never exceed the whole-order estimate beyond ceil slack
        assertLe(totalShares, estimate + asks.length, "Cumulative estimate shares should be pro-rata of the order");
    }

    function testFuzz_SurplusOut_Multifill(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 estimate,
        uint24 feeBps,
        uint24 surplusBps,
        uint256[3] memory asks
    ) public {
        balanceIn = bound(balanceIn, 1, 1e30);
        balanceOut = bound(balanceOut, 1, 1e30);
        estimate = bound(estimate, 0, 1e30);
        feeBps = uint24(bound(feeBps, 0, 0.5e7));
        surplusBps = uint24(bound(surplusBps, 1, BPS - 1));

        ISwapVM.Order memory order = _flatSurplusOrder(false, balanceIn, balanceOut, feeBps, surplusBps, estimate);
        bytes memory exactOutData = _makeTakerData(order, false);

        uint256 filled;
        uint256 totalShares;
        for (uint256 i = 0; i < asks.length; i++) {
            if (balanceOut == filled) break;

            (uint256 expectedIn, uint256 expectedOut, uint256 expectedGross, uint256 expectedFee) =
                _expectedOutFill(balanceIn, balanceOut, estimate, feeBps, surplusBps, balanceOut - filled, bound(asks[i], 1, balanceOut));

            uint256 recipientBefore = tokenB.balanceOf(feeRecipient);
            (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, bound(asks[i], 1, balanceOut), exactOutData);

            assertEq(amountIn, expectedIn);
            assertEq(amountOut, expectedOut);
            assertEq(tokenB.balanceOf(feeRecipient) - recipientBefore, expectedFee, "Flat and surplus fees should be counted against the real fill");

            filled += expectedGross;
            totalShares += estimate * expectedIn / balanceIn;
        }

        // Estimate shares across all fills never exceed the whole-order estimate beyond the input
        // rounding excess of 2 wei per fill scaled by the estimate
        assertLe(totalShares * balanceIn, estimate * (balanceIn + 2 * asks.length), "Cumulative estimate shares should be pro-rata of the order");
    }

    /// @dev Mirrors a single exact-out fill: gross output requested with the fee on top, capped by the
    ///   remaining capacity, the flat fee deducted from the gross, the surplus counted as the estimate
    ///   share shortfall against the really delivered gross
    function _expectedOutFill(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 estimate,
        uint24 feeBps,
        uint24 surplusBps,
        uint256 remaining,
        uint256 ask
    ) internal pure returns (uint256 expectedIn, uint256 expectedOut, uint256 expectedGross, uint256 expectedFee) {
        expectedGross = Math.min(ask + ask * feeBps / (BPS - feeBps), remaining);
        expectedIn = (expectedGross * (balanceIn * remaining).ceilDiv(balanceOut)).ceilDiv(remaining);
        expectedOut = expectedGross - expectedGross * feeBps / BPS;

        uint256 share = estimate * expectedIn / balanceIn;
        expectedFee = expectedGross * feeBps / BPS + (share > expectedGross ? share - expectedGross : 0) * surplusBps / BPS;
    }

    function _flatSurplusOrder(bool isTokenIn, uint256 balanceIn, uint256 balanceOut, uint24 feeBps, uint24 surplusBps, uint256 estimate) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            isTokenIn
                ? FeeBuilders.protocolFlatSurplusIn(feeBps, surplusBps, feeRecipient, uint216(estimate))
                : FeeBuilders.protocolFlatSurplusOut(feeBps, surplusBps, feeRecipient, uint216(estimate)),
            isTokenIn ? InvalidateTokenIn.build() : InvalidateTokenOut.build(),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
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

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: true,
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
