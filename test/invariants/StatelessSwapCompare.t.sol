// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test, console } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { StatelessSwap, StatelessSwapArgsBuilder } from "../../src/instructions/StatelessSwap.sol";
import { Fee, FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title StatelessSwapCompare - Compare StatelessSwap (flat fees) with XYCSwap
/// @notice Tests that fee=0 matches XYCSwap, and analyzes flat fee behavior
contract StatelessSwapCompare is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        tokenA = new MockToken("Token A", "TKA");
        tokenB = new MockToken("Token B", "TKB");

        tokenA.mint(maker, 1000000e18);
        tokenB.mint(maker, 1000000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    function _createXYCSwapOrder(uint256 balanceA, uint256 balanceB) internal view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_xycSwapXD)
        );
        return _createOrder(bytecode);
    }

    function _createStatelessSwapOrder(uint256 balanceA, uint256 balanceB, uint32 feeBps) internal view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_statelessSwap2D, StatelessSwapArgsBuilder.build2D(feeBps))
        );
        return _createOrder(bytecode);
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: program
        }));
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
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
            signature: signature
        }));

        return abi.encodePacked(takerTraits);
    }

    function _quoteSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);
        (amountIn, amountOut,) = swapVM.asView().quote(order, address(tokenA), address(tokenB), amount, takerData);
    }

    // ============================================================
    // TEST 1: StatelessSwap (fee=0) == XYCSwap
    // ============================================================

    function test_Compare_Fee0_EqualsXYCSwap_ExactIn() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 swapAmount = 10e18;

        console.log("\n=== Compare: StatelessSwap (fee=0) vs XYCSwap ===");
        console.log("Swap amount: 10e18 (exactIn)");

        // XYCSwap
        ISwapVM.Order memory xycOrder = _createXYCSwapOrder(balanceA, balanceB);
        (uint256 xycIn, uint256 xycOut) = _quoteSwap(xycOrder, swapAmount, true);
        console.log("XYCSwap:        amountIn=%s, amountOut=%s", xycIn, xycOut);

        // StatelessSwap with fee=0
        ISwapVM.Order memory statelessOrder = _createStatelessSwapOrder(balanceA, balanceB, 0);
        (uint256 statelessIn, uint256 statelessOut) = _quoteSwap(statelessOrder, swapAmount, true);
        console.log("StatelessSwap:  amountIn=%s, amountOut=%s", statelessIn, statelessOut);

        // Should be EXACTLY equal
        assertEq(xycIn, statelessIn, "amountIn should be equal");
        assertEq(xycOut, statelessOut, "amountOut should be equal (fee=0 = pure constant product)");
    }

    function test_Compare_Fee0_EqualsXYCSwap_ExactOut() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 swapAmount = 10e18;

        console.log("\n=== Compare: StatelessSwap (fee=0) vs XYCSwap (exactOut) ===");

        ISwapVM.Order memory xycOrder = _createXYCSwapOrder(balanceA, balanceB);
        (uint256 xycIn, uint256 xycOut) = _quoteSwap(xycOrder, swapAmount, false);
        console.log("XYCSwap:        amountIn=%s, amountOut=%s", xycIn, xycOut);

        ISwapVM.Order memory statelessOrder = _createStatelessSwapOrder(balanceA, balanceB, 0);
        (uint256 statelessIn, uint256 statelessOut) = _quoteSwap(statelessOrder, swapAmount, false);
        console.log("StatelessSwap:  amountIn=%s, amountOut=%s", statelessIn, statelessOut);

        assertEq(xycOut, statelessOut, "amountOut should be equal");
        // Allow 1 wei difference due to rounding in ceil division
        assertApproxEqAbs(xycIn, statelessIn, 1, "amountIn should be approximately equal");
    }

    function test_Compare_Fee0_MultipleAmounts() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;

        console.log("\n=== Compare: Multiple amounts with fee=0 ===");

        uint256[5] memory amounts = [uint256(1e18), 10e18, 50e18, 100e18, 200e18];

        for (uint i = 0; i < amounts.length; i++) {
            ISwapVM.Order memory xycOrder = _createXYCSwapOrder(balanceA, balanceB);
            (, uint256 xycOut) = _quoteSwap(xycOrder, amounts[i], true);

            ISwapVM.Order memory statelessOrder = _createStatelessSwapOrder(balanceA, balanceB, 0);
            (, uint256 statelessOut) = _quoteSwap(statelessOrder, amounts[i], true);

            console.log("Amount %s: XYC=%s, Stateless=%s", amounts[i], xycOut, statelessOut);

            assertEq(xycOut, statelessOut, "Outputs should be exactly equal");
        }
    }

    // ============================================================
    // TEST 2: Flat Fee Analysis
    // ============================================================

    function test_FlatFee_ConstantRateAllSizes() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = 30;  // 0.3%

        console.log("\n=== Flat Fee: Constant Rate All Sizes ===");
        console.log("Pool: 1000/1000, Fee: 30 bps (0.3%%)\n");

        uint256[5] memory amounts = [uint256(1e18), 10e18, 50e18, 100e18, 200e18];

        for (uint i = 0; i < amounts.length; i++) {
            ISwapVM.Order memory order = _createStatelessSwapOrder(balanceA, balanceB, feeBps);
            (, uint256 out) = _quoteSwap(order, amounts[i], true);
            
            uint256 noFeeOut = balanceB * amounts[i] / (balanceA + amounts[i]);
            uint256 feeRate = noFeeOut > out ? (noFeeOut - out) * 10000 / noFeeOut : 0;
            
            uint256 pctOfPool = amounts[i] * 100 / balanceA;
            console.log("Trade %s%% of pool: output=%s, fee=%s bps", pctOfPool, out, feeRate);

            // Fee rate should be approximately constant (~30 bps)
            assertApproxEqAbs(feeRate, 30, 6, "Fee rate should be ~30 bps");
        }
    }

    function test_FlatFee_IncreasingFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 swapAmount = 10e18;

        console.log("\n=== Flat Fee: Increasing Fee Levels ===");
        console.log("Pool: 1000/1000, Swap: 10e18\n");

        uint32[5] memory fees = [uint32(0), 30, 100, 300, 1000];

        uint256 prevOut = type(uint256).max;
        for (uint i = 0; i < fees.length; i++) {
            ISwapVM.Order memory order = _createStatelessSwapOrder(balanceA, balanceB, fees[i]);
            (, uint256 out) = _quoteSwap(order, swapAmount, true);
            
            uint256 noFeeOut = balanceB * swapAmount / (balanceA + swapAmount);
            uint256 feeRate = noFeeOut > out ? (noFeeOut - out) * 10000 / noFeeOut : 0;
            
            console.log("Fee=%s bps: output=%s, effective fee=%s bps", fees[i], out, feeRate);

            // Higher fee should give less output
            assertLe(out, prevOut, "Higher fee should give less output");
            prevOut = out;
        }
    }

    // ============================================================
    // GAS COMPARISON
    // ============================================================

    function _createFlatFeeXYCSwapOrder(
        uint256 balanceA, 
        uint256 balanceB, 
        uint32 feeBps
    ) internal view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );
        return _createOrder(bytecode);
    }

    function test_GasComparison() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 swapAmount = 10e18;

        console.log("\n=== Gas Comparison ===");
        console.log("Pool: 1000/1000, Swap: 10e18\n");

        // XYCSwap
        ISwapVM.Order memory xycOrder = _createXYCSwapOrder(balanceA, balanceB);
        uint256 gasXYC = _measureSwapGas(xycOrder, swapAmount, true);
        console.log("XYCSwap:            %s gas", gasXYC);

        // StatelessSwap fee=0
        ISwapVM.Order memory statelessOrder0 = _createStatelessSwapOrder(balanceA, balanceB, 0);
        uint256 gasStateless0 = _measureSwapGas(statelessOrder0, swapAmount, true);
        console.log("Stateless(fee=0):   %s gas", gasStateless0);

        // StatelessSwap fee=30 bps
        ISwapVM.Order memory statelessOrder30 = _createStatelessSwapOrder(balanceA, balanceB, 30);
        uint256 gasStateless30 = _measureSwapGas(statelessOrder30, swapAmount, true);
        console.log("Stateless(fee=30):  %s gas", gasStateless30);

        console.log("\nDifference XYC vs Stateless(0): %s gas", _absDiff(gasXYC, gasStateless0));
        console.log("Difference Stateless(0) vs Stateless(30): %s gas", _absDiff(gasStateless0, gasStateless30));
    }

    /// @notice Compare gas: StatelessSwap vs FlatFeeIn + XYCSwap
    function test_GasComparison_StatelessVsFlatFeeXYC() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        
        console.log("\n======================================================");
        console.log("  GAS COMPARISON: StatelessSwap vs FlatFeeIn + XYCSwap");
        console.log("======================================================");
        console.log("Pool: 1000/1000\n");
        
        uint32[4] memory fees = [uint32(30), 100, 300, 1000];
        string[4] memory feeLabels = ["30 bps (0.3%)", "100 bps (1%)", "300 bps (3%)", "1000 bps (10%)"];
        
        for (uint i = 0; i < fees.length; i++) {
            console.log("--- Fee: %s ---", feeLabels[i]);
            
            // FlatFeeIn + XYCSwap
            ISwapVM.Order memory flatFeeOrder = _createFlatFeeXYCSwapOrder(balanceA, balanceB, fees[i]);
            uint256 gasFlatFee = _measureSwapGas(flatFeeOrder, 10e18, true);
            
            // StatelessSwap
            ISwapVM.Order memory statelessOrder = _createStatelessSwapOrder(balanceA, balanceB, fees[i]);
            uint256 gasStateless = _measureSwapGas(statelessOrder, 10e18, true);
            
            console.log("  FlatFeeIn + XYCSwap: %s gas", gasFlatFee);
            console.log("  StatelessSwap:       %s gas", gasStateless);
            
            if (gasStateless > gasFlatFee) {
                console.log("  Difference: +%s gas (StatelessSwap is MORE expensive)\n", gasStateless - gasFlatFee);
            } else {
                console.log("  Difference: -%s gas (StatelessSwap is CHEAPER)\n", gasFlatFee - gasStateless);
            }
        }
    }
    
    /// @notice Detailed gas comparison with multiple swap amounts
    function test_GasComparison_VaryingAmounts() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = 30;
        
        console.log("\n======================================================");
        console.log("  GAS COMPARISON: Varying Swap Amounts (fee=30bps)");
        console.log("======================================================");
        console.log("Pool: 1000/1000\n");
        
        uint256[5] memory amounts = [uint256(1e18), 10e18, 50e18, 100e18, 200e18];
        string[5] memory amountLabels = ["1e18 (0.1%)", "10e18 (1%)", "50e18 (5%)", "100e18 (10%)", "200e18 (20%)"];
        
        console.log("Amount             | FlatFeeIn+XYC | StatelessSwap | Diff");
        console.log("-------------------|---------------|---------------|------");
        
        for (uint i = 0; i < amounts.length; i++) {
            ISwapVM.Order memory flatFeeOrder = _createFlatFeeXYCSwapOrder(balanceA, balanceB, feeBps);
            uint256 gasFlatFee = _measureSwapGas(flatFeeOrder, amounts[i], true);
            
            ISwapVM.Order memory statelessOrder = _createStatelessSwapOrder(balanceA, balanceB, feeBps);
            uint256 gasStateless = _measureSwapGas(statelessOrder, amounts[i], true);
            
            int256 diff = int256(gasStateless) - int256(gasFlatFee);
            
            console.log("%s  | %s | %s", amountLabels[i], gasFlatFee, gasStateless);
            console.logInt(diff);
        }
    }
    
    /// @notice Compare gas for ExactIn vs ExactOut
    function test_GasComparison_ExactInVsExactOut() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = 30;
        uint256 swapAmount = 10e18;
        
        console.log("\n======================================================");
        console.log("  GAS COMPARISON: ExactIn vs ExactOut (fee=30bps)");
        console.log("======================================================");
        console.log("Pool: 1000/1000, Amount: 10e18\n");
        
        // ExactIn
        console.log("--- ExactIn ---");
        ISwapVM.Order memory flatFeeOrderIn = _createFlatFeeXYCSwapOrder(balanceA, balanceB, feeBps);
        uint256 gasFlatFeeIn = _measureSwapGas(flatFeeOrderIn, swapAmount, true);
        console.log("  FlatFeeIn + XYCSwap: %s gas", gasFlatFeeIn);
        
        ISwapVM.Order memory statelessOrderIn = _createStatelessSwapOrder(balanceA, balanceB, feeBps);
        uint256 gasStatelessIn = _measureSwapGas(statelessOrderIn, swapAmount, true);
        console.log("  StatelessSwap:       %s gas", gasStatelessIn);
        
        // ExactOut
        console.log("\n--- ExactOut ---");
        ISwapVM.Order memory flatFeeOrderOut = _createFlatFeeXYCSwapOrder(balanceA, balanceB, feeBps);
        uint256 gasFlatFeeOut = _measureSwapGas(flatFeeOrderOut, swapAmount, false);
        console.log("  FlatFeeIn + XYCSwap: %s gas", gasFlatFeeOut);
        
        ISwapVM.Order memory statelessOrderOut = _createStatelessSwapOrder(balanceA, balanceB, feeBps);
        uint256 gasStatelessOut = _measureSwapGas(statelessOrderOut, swapAmount, false);
        console.log("  StatelessSwap:       %s gas", gasStatelessOut);
        
        console.log("\n--- Summary ---");
        console.log("  ExactIn diff:  %s gas", int256(gasStatelessIn) - int256(gasFlatFeeIn));
        console.log("  ExactOut diff: %s gas", int256(gasStatelessOut) - int256(gasFlatFeeOut));
    }

    function _measureSwapGas(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn
    ) internal returns (uint256 gasUsed) {
        bytes memory takerData = _signAndPackTakerData(order, isExactIn, isExactIn ? 0 : type(uint256).max);
        tokenA.mint(address(this), 1000e18);

        uint256 gasBefore = gasleft();
        swapVM.swap(order, address(tokenA), address(tokenB), amount, takerData);
        gasUsed = gasBefore - gasleft();
    }

    // ============================================================
    // CONCENTRATED LIQUIDITY
    // ============================================================

    function _createConcentratedXYCSwapOrder(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
    ) internal view returns (ISwapVM.Order memory) {
        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, price, priceMin, priceMax
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )),
            program.build(_xycSwapXD)
        );
        return _createOrder(bytecode);
    }

    function _createConcentratedStatelessSwapOrder(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax,
        uint32 feeBps
    ) internal view returns (ISwapVM.Order memory) {
        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA, balanceB, price, priceMin, priceMax
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([balanceA, balanceB])
            )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )),
            program.build(_statelessSwap2D, StatelessSwapArgsBuilder.build2D(feeBps))
        );
        return _createOrder(bytecode);
    }

    function test_Concentrated_Fee0_EqualsXYCSwap() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.8e18;
        uint256 priceMax = 1.25e18;
        uint256 swapAmount = 10e18;

        console.log("\n=== Concentrated: Fee=0 vs XYCSwap ===");

        ISwapVM.Order memory xycOrder = _createConcentratedXYCSwapOrder(
            balanceA, balanceB, price, priceMin, priceMax
        );
        (uint256 xycIn, uint256 xycOut) = _quoteSwap(xycOrder, swapAmount, true);
        console.log("XYCConcentrate + XYCSwap: out=%s", xycOut);

        ISwapVM.Order memory statelessOrder = _createConcentratedStatelessSwapOrder(
            balanceA, balanceB, price, priceMin, priceMax, 0
        );
        (uint256 statelessIn, uint256 statelessOut) = _quoteSwap(statelessOrder, swapAmount, true);
        console.log("XYCConcentrate + Stateless(0): out=%s", statelessOut);

        assertEq(xycIn, statelessIn, "amountIn should be equal");
        assertEq(xycOut, statelessOut, "amountOut should be equal");
    }

    function test_Concentrated_WithFlatFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 price = 1e18;
        uint256 priceMin = 0.8e18;
        uint256 priceMax = 1.25e18;
        uint256 swapAmount = 10e18;

        console.log("\n=== Concentrated: With Flat Fee ===");

        // No fee
        ISwapVM.Order memory order0 = _createConcentratedStatelessSwapOrder(
            balanceA, balanceB, price, priceMin, priceMax, 0
        );
        (, uint256 out0) = _quoteSwap(order0, swapAmount, true);
        console.log("Fee=0: output=%s", out0);

        // 30 bps fee
        ISwapVM.Order memory order30 = _createConcentratedStatelessSwapOrder(
            balanceA, balanceB, price, priceMin, priceMax, 30
        );
        (, uint256 out30) = _quoteSwap(order30, swapAmount, true);
        uint256 feeRate = (out0 - out30) * 10000 / out0;
        console.log("Fee=30 bps: output=%s, effective fee=%s bps", out30, feeRate);

        assertLt(out30, out0, "Fee should reduce output");
        assertApproxEqAbs(feeRate, 30, 1, "Effective fee should be ~30 bps");
    }

    // ============================================================
    // ADDITIVITY DEMONSTRATION
    // ============================================================

    function test_Additivity_Demonstration() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = 30;

        console.log("\n=== Additivity Demonstration ===");
        console.log("Pool: 1000/1000, Fee: 30 bps");
        console.log("Proving: swap(100) >= swap(50) + swap(50)\n");

        // Single swap of 100
        ISwapVM.Order memory orderSingle = _createStatelessSwapOrder(balanceA, balanceB, feeBps);
        (, uint256 singleOut) = _quoteSwap(orderSingle, 100e18, true);
        console.log("Single swap(100): output = %s", singleOut);

        // First swap of 50 (execute to update state)
        tokenA.mint(address(this), 100e18);
        ISwapVM.Order memory orderFirst = _createStatelessSwapOrder(balanceA, balanceB, feeBps);
        bytes memory takerDataFirst = _signAndPackTakerData(orderFirst, true, 0);
        (, uint256 firstOut,) = swapVM.swap(orderFirst, address(tokenA), address(tokenB), 50e18, takerDataFirst);

        // Pool after first swap: x = 1050, y = 1000 - firstOut
        uint256 newBalanceA = balanceA + 50e18;
        uint256 newBalanceB = balanceB - firstOut;
        console.log("After first swap(50): output = %s, new pool = %s/%s", firstOut, newBalanceA, newBalanceB);

        // Second swap of 50
        ISwapVM.Order memory orderSecond = _createStatelessSwapOrder(newBalanceA, newBalanceB, feeBps);
        bytes memory takerDataSecond = _signAndPackTakerData(orderSecond, true, 0);
        (, uint256 secondOut,) = swapVM.swap(orderSecond, address(tokenA), address(tokenB), 50e18, takerDataSecond);
        console.log("Second swap(50): output = %s", secondOut);

        uint256 totalSplit = firstOut + secondOut;
        console.log("\nTotal split (50+50): %s", totalSplit);
        console.log("Single (100): %s", singleOut);
        console.log("Difference: %s (single is better)", singleOut - totalSplit);

        // Additivity: single >= split
        assertGe(singleOut, totalSplit, "ADDITIVITY: single swap >= split swaps");
    }

    // ============================================================
    // HELPER
    // ============================================================

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
