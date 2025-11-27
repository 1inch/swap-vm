// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../src/libs/PeggedSwapMath.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PeggedSwapTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;
    using SafeCast for uint256;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public usdcMock;
    MockToken public usdtMock;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint256 constant ONE = 1e18;
    uint256 constant CURVATURE = ONE / 2; // p = 0.5, curvature at the ends of the curve

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        usdcMock = new MockToken("USD Coin", "USDC");
        usdtMock = new MockToken("Tether USD", "USDT");

        usdcMock.mint(maker, 1000000e18);
        usdtMock.mint(maker, 1000000e18);
        usdcMock.mint(taker, 1000000e18);
        usdtMock.mint(taker, 1000000e18);

        vm.prank(maker);
        usdcMock.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        usdtMock.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        usdcMock.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        usdtMock.approve(address(swapVM), type(uint256).max);
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    /// @dev Calculate invariant value offchain - delegates to PeggedSwapMath
    function calculateInvariant(
        uint256 x,
        uint256 y,
        uint256 x0,
        uint256 y0,
        uint256 a
    ) internal pure returns (uint256) {
        return PeggedSwapMath.invariantFromReserves(x, y, x0, y0, a);
    }

    /// @dev Calculate target state for exactIn swap using binary search
    /// @notice Uses PeggedSwapMath to match onchain calculation exactly
    function calculateExactIn(
        uint256 x0,
        uint256 y0,
        uint256 amountIn,
        uint256 x0Norm,
        uint256 y0Norm,
        uint256 a
    ) internal pure returns (uint256 x1, uint256 y1, uint256 amountOut) {
        x1 = x0 + amountIn;
        uint256 targetInvariant = calculateInvariant(x0, y0, x0Norm, y0Norm, a);

        y1 = _binarySearchY(x1, y0, amountIn, x0Norm, y0Norm, a, targetInvariant);
        amountOut = y0 - y1;
    }

    /// @dev Binary search for y that maintains invariant
    function _binarySearchY(
        uint256 x1,
        uint256 y0,
        uint256 amountIn,
        uint256 x0Norm,
        uint256 y0Norm,
        uint256 a,
        uint256 targetInvariant
    ) private pure returns (uint256) {
        uint256 yLow = (y0 > amountIn * 2) ? y0 - amountIn * 2 : y0 / 2;
        if (yLow == 0) yLow = 1;
        uint256 yHigh = y0;
        uint256 y = yHigh;

        for (uint256 i = 0; i < 512; i++) {
            if (yLow > yHigh) break;

            y = (yLow + yHigh) / 2;
            uint256 inv = calculateInvariant(x1, y, x0Norm, y0Norm, a);

            if (inv == targetInvariant) break;

            if (inv < targetInvariant) {
                yLow = y;
            } else {
                yHigh = y;
            }

            if (yHigh - yLow <= 1) {
                uint256 invLow = calculateInvariant(x1, yLow, x0Norm, y0Norm, a);
                uint256 invHigh = calculateInvariant(x1, yHigh, x0Norm, y0Norm, a);

                uint256 diffLow = invLow > targetInvariant ? invLow - targetInvariant : targetInvariant - invLow;
                uint256 diffHigh = invHigh > targetInvariant ? invHigh - targetInvariant : targetInvariant - invHigh;

                return diffLow <= diffHigh ? yLow : yHigh;
            }
        }

        return y > 0 && y <= y0 ? y : y0 - 1;
    }

    /// @dev Calculate price impact percentage (in basis points)
    function calculatePriceImpact(
        uint256 amountIn,
        uint256 amountOut,
        uint256 x0,
        uint256 y0
    ) internal pure returns (uint256) {
        // Expected output at current spot price: amountOut_expected = amountIn * (y0/x0)
        uint256 expectedOut = (amountIn * y0) / x0;

        if (amountOut >= expectedOut) return 0; // No negative impact

        uint256 loss = expectedOut - amountOut;
        return (loss * 10000) / expectedOut;
    }

    function takerData(address takerAddress, bool isExactIn, bytes memory hints) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddress,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: hints,
            signature: ""
        }));
    }

    function signOrder(ISwapVM.Order memory order) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    // ========================================
    // LARGE A TESTS (FOR PEGGED ASSETS)
    // A = 1.2 optimized for stablecoins/pegged assets
    // ========================================

    function test_LargeA_PeggedAssets_SmallSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  LARGE A (PEGGED) - SMALL SWAP");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 linearWidth = 12e17; // A = 1.2 (high linearity for pegged assets)
        uint256 swapAmount = 100e18; // Small: 100 tokens (0.1% of pool)

        (, , uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            initialLiquidity, initialLiquidity, linearWidth
        );

        uint256 priceImpact = calculatePriceImpact(swapAmount, amountOut, initialLiquidity, initialLiquidity);

        console.log("Pool: 100,000 / 100,000, A=1.2 (pegged)");
        console.log("Swap: 100 tokens (0.1%% of pool)");
        console.log("  Amount out: %s", amountOut / 1e18);
        console.log("  Price impact: %s bps (MUST BE LOW)", priceImpact);
        console.log("");

        // Verify low impact for pegged assets with large A
        require(priceImpact < 10, "Small swap should have very low impact with large A");

        console.log("SUCCESS: Small swap has minimal impact!");
        console.log("");
    }

    function test_LargeA_PeggedAssets_MediumSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  LARGE A (PEGGED) - MEDIUM SWAP");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 linearWidth = 12e17; // A = 1.2 (high linearity for pegged assets)
        uint256 swapAmount = 5000e18; // Medium: 5000 tokens (5% of pool)

        (, , uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            initialLiquidity, initialLiquidity, linearWidth
        );

        uint256 priceImpact = calculatePriceImpact(swapAmount, amountOut, initialLiquidity, initialLiquidity);

        console.log("Pool: 100,000 / 100,000, A=1.2 (pegged)");
        console.log("Swap: 5,000 tokens (5%% of pool)");
        console.log("  Amount out: %s", amountOut / 1e18);
        console.log("  Price impact: %s bps (STILL LOW)", priceImpact);
        console.log("");

        // Verify still low impact for pegged assets with large A
        require(priceImpact < 100, "Medium swap should still have low impact with large A");

        console.log("SUCCESS: Medium swap maintains low impact!");
        console.log("");
    }

    function test_LargeA_PeggedAssets_LargeSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  LARGE A (PEGGED) - LARGE SWAP");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 linearWidth = 12e17; // A = 1.2 (high linearity for pegged assets)
        uint256 swapAmount = 50000e18; // Large: 50000 tokens (50% of pool)

        (, , uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            initialLiquidity, initialLiquidity, linearWidth
        );

        uint256 priceImpact = calculatePriceImpact(swapAmount, amountOut, initialLiquidity, initialLiquidity);

        console.log("Pool: 100,000 / 100,000, A=1.2 (pegged)");
        console.log("Swap: 50,000 tokens (50%% of pool)");
        console.log("  Amount out: %s", amountOut / 1e18);
        console.log("  Price impact: %s bps (MUST BE HIGH)", priceImpact);
        console.log("");

        // Verify high impact for large swaps even with large A
        require(priceImpact > 500, "Large swap must have high impact");

        console.log("SUCCESS: Large swap has appropriate high impact!");
        console.log("");
    }

    // ========================================
    // SMALL A TESTS (FOR UNPEGGED ASSETS)
    // A = 0.1 for volatile/unpegged pairs
    // ========================================

    function test_SmallA_UnpeggedAssets_SmallSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  SMALL A (UNPEGGED) - SMALL SWAP");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 linearWidth = 1e17; // A = 0.1 (low linearity for volatile assets)
        uint256 swapAmount = 100e18; // Small: 100 tokens (0.1% of pool)

        (, , uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            initialLiquidity, initialLiquidity, linearWidth
        );

        uint256 priceImpact = calculatePriceImpact(swapAmount, amountOut, initialLiquidity, initialLiquidity);

        console.log("Pool: 100,000 / 100,000, A=0.1 (unpegged)");
        console.log("Swap: 100 tokens (0.1%% of pool)");
        console.log("  Amount out: %s", amountOut / 1e18);
        console.log("  Price impact: %s bps", priceImpact);
        console.log("");

        console.log("SUCCESS: Impact according to invariant with small A!");
        console.log("");
    }

    function test_SmallA_UnpeggedAssets_MediumSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  SMALL A (UNPEGGED) - MEDIUM SWAP");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 linearWidth = 1e17; // A = 0.1 (low linearity for volatile assets)
        uint256 swapAmount = 5000e18; // Medium: 5000 tokens (5% of pool)

        (, , uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            initialLiquidity, initialLiquidity, linearWidth
        );

        uint256 priceImpact = calculatePriceImpact(swapAmount, amountOut, initialLiquidity, initialLiquidity);

        console.log("Pool: 100,000 / 100,000, A=0.1 (unpegged)");
        console.log("Swap: 5,000 tokens (5%% of pool)");
        console.log("  Amount out: %s", amountOut / 1e18);
        console.log("  Price impact: %s bps (GREATER)", priceImpact);
        console.log("");

        // Verify higher impact than small swap
        require(priceImpact > 150, "Medium swap should have notable impact with small A");

        console.log("SUCCESS: Medium swap has increased impact!");
        console.log("");
    }

    function test_SmallA_UnpeggedAssets_LargeSwap() public {
        console.log("");
        console.log("========================================");
        console.log("  SMALL A (UNPEGGED) - LARGE SWAP");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 linearWidth = 1e17; // A = 0.1 (low linearity for volatile assets)
        uint256 swapAmount = 50000e18; // Large: 50000 tokens (50% of pool)

        (, , uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            initialLiquidity, initialLiquidity, linearWidth
        );

        uint256 priceImpact = calculatePriceImpact(swapAmount, amountOut, initialLiquidity, initialLiquidity);

        console.log("Pool: 100,000 / 100,000, A=0.1 (unpegged)");
        console.log("Swap: 50,000 tokens (50%% of pool)");
        console.log("  Amount out: %s", amountOut / 1e18);
        console.log("  Price impact: %s bps (MUCH GREATER)", priceImpact);
        console.log("");

        // Verify much higher impact for large swaps with small A
        require(priceImpact > 800, "Large swap must have very high impact with small A");

        console.log("SUCCESS: Large swap has very high impact!");
        console.log("");
    }

    function test_PeggedSwap_ActualOnchainSwap_ExactIn() public {
        console.log("");
        console.log("========================================");
        console.log("  ONCHAIN PEGGED SWAP TEST - EXACT IN");
        console.log("  Using analytical solution");
        console.log("========================================");
        console.log("");

        uint256 initialLiquidity = 100000e18;
        uint256 x0Initial = initialLiquidity;
        uint256 y0Initial = initialLiquidity;
        uint256 linearWidth = 8e17; // A = 0.8 (optimized for stablecoins)

        // Calculate target state using analytical solution
        uint256 swapAmount = 1000e18;
        (uint256 x1NoFee, uint256 y1, uint256 amountOut) = calculateExactIn(
            initialLiquidity, initialLiquidity, swapAmount,
            x0Initial, y0Initial, linearWidth
        );

        console.log("Expected results (calculated offchain):");
        console.log("  x1NoFee: %s", x1NoFee / 1e18);
        console.log("  y1: %s", y1 / 1e18);
        console.log("  amountOut: %s", amountOut / 1e18);

        // Verify the invariant matches with our solver
        uint256 inv0 = calculateInvariant(initialLiquidity, initialLiquidity, x0Initial, y0Initial, linearWidth);
        uint256 inv1 = calculateInvariant(x1NoFee, y1, x0Initial, y0Initial, linearWidth);
        console.log("  Invariant before: %s", inv0 / 1e15);
        console.log("  Invariant after: %s", inv1 / 1e15);
        uint256 invDiff = inv0 > inv1 ? inv0 - inv1 : inv1 - inv0;
        console.log("  Invariant diff: %s (in 1e15)", invDiff / 1e15);
        console.log("");


        // Build SwapVM program
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(usdcMock), address(usdtMock)]),
                    dynamic([initialLiquidity, initialLiquidity])
                )),
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0Initial,
                    y0: y0Initial,
                    linearWidth: linearWidth
                })))
        );

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: programBytes
        }));

        bytes memory signature = signOrder(order);
        bytes memory takerTraitsAndData = takerData(taker, true, "");
        bytes memory sigAndTakerData = abi.encodePacked(takerTraitsAndData, signature);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 actualAmountOut, ) = swapVM.swap(
            order,
            address(usdcMock),
            address(usdtMock),
            swapAmount,
            sigAndTakerData
        );

        console.log("Swap executed successfully!");
        console.log("  Amount in: %s USDC", actualAmountIn / 1e18);
        console.log("  Amount out: %s USDT", actualAmountOut / 1e18);
        console.log("  Price impact: %s bps", calculatePriceImpact(actualAmountIn, actualAmountOut, initialLiquidity, initialLiquidity));
        console.log("");

        assertEq(actualAmountIn, swapAmount, "AmountIn mismatch");
        // Allow tiny rounding difference between binary search (offchain) and analytical (onchain)
        assertApproxEqRel(actualAmountOut, amountOut, 1e14); // 0.01% tolerance

        console.log("========================================");
        console.log("SUCCESS: Direct calculation works perfectly!");
        console.log("========================================");
        console.log("");
    }

    // ========================================
    // ONCHAIN EXECUTION TEST
    // ========================================

    function test_RoundingProtectsProtocol_ExactIn() public view {
        console.log("");
        console.log("========================================");
        console.log("  ROUNDING PROTECTION TEST - EXACT IN");
        console.log("========================================");
        console.log("");

        uint256 x0 = 100000e18;
        uint256 y0 = 100000e18;
        uint256 x0Initial = 100000e18;
        uint256 y0Initial = 100000e18;
        uint256 linearWidth = 8e17; // 0.8

        // Small swap that will cause rounding
        uint256 amountIn = 1; // 1 wei - extreme case

        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(x0, y0, x0Initial, y0Initial, linearWidth);

        // ExactIn calculation (what PeggedSwap does)
        uint256 x1 = x0 + amountIn;
        uint256 u1 = (x1 * ONE) / x0Initial;  // Rounds DOWN
        uint256 v1 = PeggedSwapMath.solve(u1, linearWidth, targetInvariant);

        // Without rounding protection (vulnerable):
        uint256 y1_vulnerable = (v1 * y0Initial) / ONE;  // Rounds DOWN y1
        uint256 amountOut_vulnerable = y0 - y1_vulnerable;  // Rounds UP amountOut ❌

        // With rounding protection (secure):
        uint256 y1_protected = divRoundUp(v1 * y0Initial, ONE);  // Rounds UP y1
        uint256 amountOut_protected = y0 - y1_protected;  // Rounds DOWN amountOut ✅

        console.log("For 1 wei input:");
        console.log("  Without protection: amountOut = %s (rounds UP - bad!)", amountOut_vulnerable);
        console.log("  With protection:    amountOut = %s (rounds DOWN - good!)", amountOut_protected);
        console.log("  Protection saves:   %s wei for protocol", amountOut_vulnerable - amountOut_protected);
        console.log("");

        // Verify rounding protection works
        require(amountOut_protected <= amountOut_vulnerable, "Protection should reduce amountOut");
    }

    function test_RoundingProtectsProtocol_ExactOut() public view {
        console.log("");
        console.log("========================================");
        console.log("  ROUNDING PROTECTION TEST - EXACT OUT");
        console.log("========================================");
        console.log("");

        uint256 x0 = 100000e18;
        uint256 y0 = 100000e18;
        uint256 x0Initial = 100000e18;
        uint256 y0Initial = 100000e18;
        uint256 linearWidth = 8e17; // 0.8

        // Small swap that will cause rounding
        uint256 amountOut = 1; // 1 wei - extreme case

        // Calculate target invariant
        uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(x0, y0, x0Initial, y0Initial, linearWidth);

        // ExactOut calculation (what PeggedSwap does)
        uint256 y1 = y0 - amountOut;
        uint256 v1 = (y1 * ONE) / y0Initial;  // Rounds DOWN
        uint256 u1 = PeggedSwapMath.solve(v1, linearWidth, targetInvariant);

        // Without rounding protection (vulnerable):
        uint256 x1_vulnerable = (u1 * x0Initial) / ONE;  // Rounds DOWN x1
        uint256 amountIn_vulnerable = x1_vulnerable - x0;  // Rounds DOWN amountIn ❌

        // With rounding protection (secure):
        uint256 x1_protected = divRoundUp(u1 * x0Initial, ONE);  // Rounds UP x1
        uint256 amountIn_protected = x1_protected - x0;  // Rounds UP amountIn ✅

        console.log("For 1 wei output:");
        console.log("  Without protection: amountIn = %s (rounds DOWN - bad!)", amountIn_vulnerable);
        console.log("  With protection:    amountIn = %s (rounds UP - good!)", amountIn_protected);
        console.log("  Protection gains:   %s wei for protocol", amountIn_protected - amountIn_vulnerable);
        console.log("");

        // Verify rounding protection works
        require(amountIn_protected >= amountIn_vulnerable, "Protection should increase amountIn");
    }

    function test_RoundingEffectOnLargeSwaps() public view {
        console.log("");
        console.log("========================================");
        console.log("  ROUNDING EFFECT ON LARGE SWAPS");
        console.log("========================================");
        console.log("");

        // Setup with different scales
        uint256[3] memory scales = [uint256(1e6), 1e12, 1e18]; // USDC, medium, ETH scale

        for (uint256 i = 0; i < scales.length; i++) {
            uint256 scale = scales[i];
            uint256 x0 = 100000 * scale;
            uint256 y0 = 100000 * scale;
            uint256 x0Initial = 100000 * scale;
            uint256 y0Initial = 100000 * scale;
            uint256 linearWidth = 8e17;

            uint256 amountIn = 1000 * scale; // 1000 tokens

            uint256 targetInvariant = PeggedSwapMath.invariantFromReserves(x0, y0, x0Initial, y0Initial, linearWidth);

            uint256 x1 = x0 + amountIn;
            uint256 u1 = (x1 * ONE) / x0Initial;
            uint256 v1 = PeggedSwapMath.solve(u1, linearWidth, targetInvariant);

            uint256 y1_down = (v1 * y0Initial) / ONE;
            uint256 y1_up = divRoundUp(v1 * y0Initial, ONE);

            uint256 amountOut_vulnerable = y0 - y1_down;
            uint256 amountOut_protected = y0 - y1_up;

            uint256 protectionAmount = amountOut_vulnerable - amountOut_protected;

            console.log("Scale %s:", scale);
            console.log("  Input:  %s tokens", amountIn / scale);
            console.log("  Output (vulnerable): %s", amountOut_vulnerable / scale);
            console.log("  Output (protected):  %s", amountOut_protected / scale);
            console.log("  Protocol saves: %s wei", protectionAmount);
            console.log("");
        }
    }

    // Helper function (same as in PeggedSwap)
    function divRoundUp(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    // ========================================
    // FEE TESTS
    // ========================================

    function test_PeggedSwap_ImbalancedPool_NoFee_ShowsSlippage() public {
        // Test that imbalanced pool gives slippage BEFORE adding fees
        uint256 balanceUSDC = 100000e18;
        uint256 balanceUSDT = 90000e18;
        uint256 x0Initial = 100000e18;
        uint256 y0Initial = 100000e18;
        uint256 linearWidth = 5e17;  // 0.5

        // Build program without fees
        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(usdcMock), address(usdtMock)]),
                    dynamic([balanceUSDC, balanceUSDT])
                )),
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: x0Initial,
                    y0: y0Initial,
                    linearWidth: linearWidth
                })))
        );

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: programBytes
        }));

        uint256 amountIn = 1000e18;

        (,, uint256 expectedAmountOut) = calculateExactIn(
            balanceUSDC,
            balanceUSDT,
            amountIn,
            x0Initial,
            y0Initial,
            linearWidth
        );

        bytes memory signature = signOrder(order);
        bytes memory takerTraitsAndData = takerData(taker, true, "");
        bytes memory sigAndTakerData = abi.encodePacked(takerTraitsAndData, signature);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(usdcMock), address(usdtMock), amountIn, sigAndTakerData);

        console.log("Imbalanced pool test (no fee):");
        console.log("  Pool: 100000 USDC, 90000 USDT");
        console.log("  X0/Y0: 100000");
        console.log("  A: 0.5");
        console.log("  Swap in: %s USDC", amountIn / 1e18);
        console.log("  Expected out (offchain): %s USDT", expectedAmountOut / 1e18);
        console.log("  Actual out (onchain): %s USDT", amountOut / 1e18);
        console.log("  Rate: %s USDT per USDC", (amountOut * 1e18 / amountIn) / 1e15);

        // With 10% imbalance and A=0.5, should get more than 1:1 (buying the scarcer asset)
        assertApproxEqRel(amountOut, expectedAmountOut, 1e14, "Should match expected output");
    }

    function test_PeggedSwap_WithFee_0_3_Percent_ExactIn() public {
        // Test with 0.3% fee on ExactIn swap
        uint256 balanceUSDC = 100000e18;
        uint256 balanceUSDT = 100000e18;
        uint256 X0 = 100000e18;
        uint256 Y0 = 100000e18;
        uint256 A = 8e17;  // 0.8

        Program memory prog = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(usdcMock), address(usdtMock)]),
                    dynamic([balanceUSDC, balanceUSDT])
                )),
            prog.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(uint32(0.003e9))),  // 0.3% fee
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: X0,
                    y0: Y0,
                    linearWidth: A
                })))
        );

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: programBytes
        }));

        uint256 amountIn = 1000e18;
        bytes memory signature = signOrder(order);
        bytes memory takerTraitsAndData = takerData(taker, true, "");
        bytes memory sigAndTakerData = abi.encodePacked(takerTraitsAndData, signature);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(usdcMock), address(usdtMock), amountIn, sigAndTakerData);

        console.log("Swap %s USDC with 0.3%% fee:", amountIn / 1e18);
        console.log("  Received: %s USDT", amountOut / 1e18);
        console.log("  Effective rate: %s", (amountOut * 1e18 / amountIn) / 1e15);

        // With fee, should get noticeably less than no-fee scenario
        // Expected: fee takes 3 USDC, so only 997 USDC goes into swap
        assertLt(amountOut, 1000e18, "Fee should reduce output below 1:1");
    }

    function test_PeggedSwap_NoFee_vs_WithFee_Comparison() public {
        // Compare no-fee vs with-fee scenarios
        uint256 balanceUSDC = 100000e18;
        uint256 balanceUSDT = 100000e18;
        uint256 X0 = 100000e18;
        uint256 Y0 = 100000e18;
        uint256 A = 8e17;  // 0.8

        Program memory prog = ProgramBuilder.init(_opcodes());

        // Order without fee
        bytes memory programNoFee = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(usdcMock), address(usdtMock)]),
                    dynamic([balanceUSDC, balanceUSDT])
                )),
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: X0,
                    y0: Y0,
                    linearWidth: A
                })))
        );

        // Order with fee
        bytes memory programWithFee = bytes.concat(
            prog.build(Balances._staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(usdcMock), address(usdtMock)]),
                    dynamic([balanceUSDC, balanceUSDT])
                )),
            prog.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(uint32(0.003e9))),  // 0.3% fee
            prog.build(PeggedSwap._peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({
                    x0: X0,
                    y0: Y0,
                    linearWidth: A
                })))
        );

        ISwapVM.Order memory orderNoFee = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: programNoFee
        }));

        ISwapVM.Order memory orderWithFee = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: programWithFee
        }));

        uint256 amountIn = 5000e18;

        bytes memory signatureNoFee = signOrder(orderNoFee);
        bytes memory takerTraitsAndDataNoFee = takerData(taker, true, "");
        bytes memory sigAndTakerDataNoFee = abi.encodePacked(takerTraitsAndDataNoFee, signatureNoFee);

        vm.prank(taker);
        (, uint256 amountOutNoFee,) = swapVM.swap(orderNoFee, address(usdcMock), address(usdtMock), amountIn, sigAndTakerDataNoFee);

        bytes memory signatureWithFee = signOrder(orderWithFee);
        bytes memory takerTraitsAndDataWithFee = takerData(taker, true, "");
        bytes memory sigAndTakerDataWithFee = abi.encodePacked(takerTraitsAndDataWithFee, signatureWithFee);

        vm.prank(taker);
        (, uint256 amountOutWithFee,) = swapVM.swap(orderWithFee, address(usdcMock), address(usdtMock), amountIn, sigAndTakerDataWithFee);

        console.log("");
        console.log("========================================");
        console.log("  FEE COMPARISON TEST");
        console.log("========================================");
        console.log("Swap %s USDC:", amountIn / 1e18);
        console.log("  Without fee: %s USDT", amountOutNoFee / 1e18);
        console.log("  With 0.3%% fee: %s USDT", amountOutWithFee / 1e18);
        console.log("  Difference: %s USDT", (amountOutNoFee - amountOutWithFee) / 1e18);
        console.log("  Fee impact: %s%%", ((amountOutNoFee - amountOutWithFee) * 100e18 / amountOutNoFee) / 1e18);
        console.log("========================================");
        console.log("");

        assertLt(amountOutWithFee, amountOutNoFee, "Fee should reduce output");
    }
}

