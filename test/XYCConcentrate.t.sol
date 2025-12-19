// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { dynamic } from "./utils/Dynamic.sol";
import { Vm } from "forge-std/Vm.sol";
import { FormatLib } from "./utils/FormatLib.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";


contract ConcentrateTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using FormatLib for Vm;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function assertNotApproxEqRel(uint256 left, uint256 right, uint256 maxDelta, string memory err) internal{
        if (left > right * (1e18 - maxDelta) / 1e18 && left < right * (1e18 + maxDelta) / 1e18) {
            // "%s: %s ~= %s (max delta: %s%%, real delta: %s%%)"
            fail(string.concat(
                err,
                ": ",
                Strings.toString(left),
                " ~= ",
                Strings.toString(right),
                " (max delta: ",
                vm.toFixedString(maxDelta * 100),
                "%, real delta: ",
                vm.toFixedString(left > right ? (left - right) * 100e18 / right : (right - left) * 100e18 / left),
                "%)"
            ));
        }
    }

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy custom SwapVM router
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 1_000_000_000e18);
        TokenMock(tokenB).mint(maker, 1_000_000_000e18);
        TokenMock(tokenA).mint(taker, 1_000_000_000e18);
        TokenMock(tokenB).mint(taker, 1_000_000_000e18);

        // Approve SwapVM to spend tokens by maker
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        // Approve SwapVM to spend tokens by taker
        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }

    struct MakerSetup {
        bool growLiquidityInsteadOfPriceRange;
        uint256 balanceA;
        uint256 balanceB;
        uint256 flatFee;     // 0.003e9 - 0.3% flat fee
        uint256 priceBoundA; // 0.01e18 - concentrate tokenA to 100x
        uint256 priceBoundB; // 25e18 - concentrate tokenB to 25x
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        (uint256 deltaA, uint256 deltaB, uint256 liquidity) =
            XYCConcentrateArgsBuilder.computeDeltas(setup.balanceA, setup.balanceB, 1e18, setup.priceBoundA, setup.priceBoundB);

        Program memory program = ProgramBuilder.init(_opcodes());
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
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
            program: bytes.concat(
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([setup.balanceA, setup.balanceB])
                )),
                setup.growLiquidityInsteadOfPriceRange ?
                    program.build(XYCConcentrate._xycConcentrateGrowLiquidity2D, XYCConcentrateArgsBuilder.build2D(
                        tokenA, tokenB, deltaA, deltaB, liquidity
                    )) :
                    program.build(XYCConcentrate._xycConcentrateGrowPriceRange2D, XYCConcentrateArgsBuilder.build2D(
                        tokenA, tokenB, deltaA, deltaB, liquidity
                    )),
                program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(setup.flatFee.toUint32())),
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    struct TakerSetup {
        bool isExactIn;
    }

    function _quotingTakerData(TakerSetup memory takerSetup) internal view returns (bytes memory takerData) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: takerSetup.isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "", // no minimum output
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function _swappingTakerData(bytes memory takerData, bytes memory signature) internal view returns (bytes memory) {
        // Just need to rebuild the takerData with signature for swapping
        // Since the original takerData was built for quoting (with empty signature),
        // we need to extract the isExactIn flag first (first two bytes contain flags)
        bool isExactIn = (uint16(bytes2(takerData)) & 0x0001) != 0;

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
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
            signature: signature
        }));
    }

    function test_QuoteAndSwapExactOutAmountsMatches() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Buy all tokenB liquidity
        uint256 amountOut = setup.balanceB;
        (uint256 quoteAmountIn,,) = swapVM.asView().quote(order, tokenA, tokenB, amountOut, quoteExactOut);
        vm.prank(taker);
        (uint256 swapAmountIn,,) = swapVM.swap(order, tokenA, tokenB, amountOut, swapExactOut);

        assertEq(swapAmountIn, quoteAmountIn, "Quoted amountIn should match swapped amountIn");
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForTokenA() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check quotes before and after buying all tokenA liquidity
        (uint256 preAmountIn, uint256 preAmountOut,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapExactOut);
        (uint256 postAmountIn, uint256 postAmountOut,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Compute and compare rate change
        uint256 preRate = preAmountIn * 1e18 / preAmountOut;
        uint256 postRate = postAmountIn * 1e18 / postAmountOut;
        uint256 rateChange = preRate * 1e18 / postRate;
        assertApproxEqRel(rateChange, setup.priceBoundA, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForTokenB() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check quotes before and after buying all tokenB liquidity
        (uint256 preAmountIn, uint256 preAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, setup.balanceB, swapExactOut);
        (uint256 postAmountIn, uint256 postAmountOut,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change
        uint256 preRate = preAmountIn * 1e18 / preAmountOut;
        uint256 postRate = postAmountIn * 1e18 / postAmountOut;
        uint256 rateChange = postRate * 1e18 / preRate;
        assertApproxEqRel(rateChange, setup.priceBoundB, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForBothTokensNoFee() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0,           // No fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Buy all tokenA
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenA");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenB");
    }

    function test_ConcentrateGrowLiquidity_KeepsPriceRangeForBothTokensWithFee() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Buy all tokenA
        vm.prank(taker);
        swapVM.swap(order, tokenB, tokenA, setup.balanceA, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
        (uint256 postAmountInA, uint256 postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

        // Buy all tokenB
        uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
        vm.prank(taker);
        swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapExactOut);
        assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
        (uint256 postAmountInB, uint256 postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenA");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.01e18, "Quote should be within 1% range of actual paid scaled by scaleB for tokenB");
    }

    function test_ConcentrateGrowLiquidity_SpreadSlowlyGrowsForSomeReason() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Check tokenA and tokenB prices before
        (uint256 preAmountInA, uint256 preAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);
        (uint256 preAmountInB, uint256 preAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);

        uint256 postAmountInA;
        uint256 postAmountOutA;
        uint256 postAmountInB;
        uint256 postAmountOutB;
        for (uint256 i = 0; i < 100; i++) {
            // Buy all tokenA
            uint256 balanceTokenA = swapVM.balances(swapVM.hash(order), address(tokenA));
            if (i == 0) {
                balanceTokenA = setup.balanceA; // First iteration doesn't have balances in the state yet
            }
            vm.prank(taker);
            swapVM.swap(order, tokenB, tokenA, balanceTokenA, swapExactOut);
            assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenA)), "All tokenA liquidity should be bought out");
            (postAmountInA, postAmountOutA,) = swapVM.asView().quote(order, tokenB, tokenA, 0.001e18, quoteExactOut);

            // Buy all tokenB
            uint256 balanceTokenB = swapVM.balances(swapVM.hash(order), address(tokenB));
            vm.prank(taker);
            swapVM.swap(order, tokenA, tokenB, balanceTokenB, swapExactOut);
            assertEq(0, swapVM.balances(swapVM.hash(order), address(tokenB)), "All tokenB liquidity should be bought out");
            (postAmountInB, postAmountOutB,) = swapVM.asView().quote(order, tokenA, tokenB, 0.001e18, quoteExactOut);
        }

        // Compute and compare rate change for tokenA
        uint256 preRateA = preAmountInA * 1e18 / preAmountOutA;
        uint256 postRateA = postAmountInA * 1e18 / postAmountOutA;
        uint256 rateChangeA = preRateA * 1e18 / postRateA;
        assertNotApproxEqRel(rateChangeA, setup.priceBoundA, 0.001e18, "Quote should not be within 1% range of actual paid scaled by scaleB for tokenA");
        assertApproxEqRel(rateChangeA, setup.priceBoundA, 0.005e18, "Quote should be within 2% range of actual paid scaled by scaleB for tokenA");

        // Compute and compare rate change for tokenB
        uint256 preRateB = preAmountInB * 1e18 / preAmountOutB;
        uint256 postRateB = postAmountInB * 1e18 / postAmountOutB;
        uint256 rateChangeB = postRateB * 1e18 / preRateB;
        assertNotApproxEqRel(rateChangeB, setup.priceBoundB, 0.001e18, "Quote should not be within 1% range of actual paid scaled by scaleB for tokenB");
        assertApproxEqRel(rateChangeB, setup.priceBoundB, 0.005e18, "Quote should be within 2% range of actual paid scaled by scaleB for tokenB");
    }

    function test_ConcentrateGrowLiquidity_ImpossibleSwapTokenNotInActiveStrategy() public {
        MakerSetup memory setup = MakerSetup({
            growLiquidityInsteadOfPriceRange: true,
            balanceA: 20000e18,
            balanceB: 3000e18,
            flatFee: 0.003e9,     // 0.3% flat fee
            priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
            priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        vm.startPrank(taker);
        TokenMock malToken = new TokenMock("Malicious token", "MTK");

        // Setup taker traits and data
        bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
        bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

        // Buy all tokenB liquidity
        bytes memory tokenAddresses = abi.encodePacked(tokenA, tokenB);
        vm.expectRevert(abi.encodeWithSelector(Balances.DynamicBalancesLoadingRequiresSettingBothBalances.selector, address(malToken), tokenB, tokenAddresses));
        swapVM.swap(order, address(malToken), tokenB, setup.balanceB, swapExactOut);
    }

    // TODO: Move this test to general SwapVM tests since it's not specific to XYCConcentrate
    // function test_ConcentrateGrowLiquidity_ImpossibleSwapSameToken() public {
    //     MakerSetup memory setup = MakerSetup({
    //         growLiquidityInsteadOfPriceRange: true,
    //         balanceA: 20000e18,
    //         balanceB: 3000e18,
    //         flatFee: 0.003e9,     // 0.3% flat fee
    //         priceBoundA: 0.01e18, // XYCConcentrate tokenA to 100x
    //         priceBoundB: 25e18    // XYCConcentrate tokenB to 25x
    //     });
    //     (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

    //     vm.startPrank(taker);

    //     // Setup taker traits and data
    //     bytes memory quoteExactOut = _quotingTakerData(TakerSetup({ isExactIn: false }));
    //     bytes memory swapExactOut = _swappingTakerData(quoteExactOut, signature);

    //     // Buy all tokenB liquidity
    //     vm.expectRevert(MakerTraitsLib.MakerTraitsTokenInAndTokenOutMustBeDifferent.selector);
    //     swapVM.swap(order, tokenB, tokenB, setup.balanceB, swapExactOut);
    // }
}
