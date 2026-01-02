// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Fee, BPS } from "../src/instructions/Fee.sol";
import { FeeExperimental } from "../src/instructions/FeeExperimental.sol";
import { Context, VM, SwapQuery, SwapRegisters, ContextLib } from "../src/libs/VM.sol";

/**
 * @title UniversalFeeTest
 * @notice Proves that Fee module works independently of swap formula
 * @dev Tests FeeIn/FeeOut with different swap formulas to show consistent behavior
 */
contract FeeIndifferencyToSwap is Test, FeeExperimental {
    using ContextLib for Context;
    using CalldataPtrLib for CalldataPtr;

    uint256 constant ONE = 1e18;

    constructor() FeeExperimental(address(0)) {}

    /**
     * @notice Creates a mock Context with custom swap formula
     * @param balanceIn Initial balance of input token
     * @param balanceOut Initial balance of output token
     * @param amount Swap amount (input for exactIn, output for exactOut)
     * @param exactIn Whether this is exactIn or exactOut swap
     * @param instruction Swap instruction to use
     */
    function createContextWithSpecificInstruction(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        bool exactIn,
        function(Context memory, bytes calldata) internal instruction
    ) internal view returns (Context memory ctx) {
        // Setup SwapRegisters
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = exactIn ? amount : 0;
        ctx.swap.amountOut = exactIn ? 0 : amount;

        // Setup SwapQuery
        ctx.query.isExactIn = exactIn;

        // Setup VM with our custom opcodes
        ctx.vm.opcodes = new function(Context memory, bytes calldata) internal[](256);
        ctx.vm.opcodes[0] = instruction;
        ctx.vm.nextPC = 0;
        ctx.vm.isStaticContext = true;

        bytes memory programBytes = hex"0000"; // opcode 0, args length 0
        ctx.vm.programPtr = this.getProgramPtr(programBytes);
    }

    // Helper to get calldata pointer
    function getProgramPtr(bytes calldata programBytes) external pure returns (CalldataPtr ptr) {
        return CalldataPtrLib.from(programBytes);
    }

    /**
     * @notice Checks that exactIn and exactOut give consistent exchange rates
     * @param swapInstruction Swap formula to test
     * @param balanceIn Initial input token balance
     * @param balanceOut Initial output token balance
     * @param feeBps Fee in basis points
     * @param isFeeIn Whether to test feeIn (true) or feeOut (false)
     */
    function checkExactInExactOutSymmetry(
        function(Context memory, bytes calldata) internal swapInstruction,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 feeBps,
        bool isFeeIn
    ) internal {
        uint256 inputAmount = 10e18; // Use smaller amount to avoid overflow

        // Step 1: ExactIn swap
        Context memory ctxExactIn = createContextWithSpecificInstruction(
            balanceIn, balanceOut, inputAmount, true, swapInstruction
        );

        isFeeIn ? _feeAmountIn(ctxExactIn, feeBps) : _feeAmountOut(ctxExactIn, feeBps);

        // Step 2: ExactOut swap requesting the same outputAmount
        Context memory ctxExactOut = createContextWithSpecificInstruction(
            balanceIn, balanceOut, ctxExactIn.swap.amountOut, false, swapInstruction
        );

        isFeeIn ? _feeAmountIn(ctxExactOut, feeBps) : _feeAmountOut(ctxExactOut, feeBps);

        // Step 3: Verify symmetry of ExactIn and ExactOut
        // For inverse formula, we need higher tolerance due to division operations
        uint256 tolerance = (swapInstruction == inverseFormula) ? 12000 : 2;
        assertApproxEqAbs(ctxExactOut.swap.amountIn, inputAmount, tolerance, "Exchange rate inconsistent between exactIn and exactOut");
    }

    function test_FeeIn_WithXYCFormula() public {
        checkExactInExactOutSymmetry(
            xycFormula,
            100e18, // balanceIn
            200e18, // balanceOut
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }

    function test_FeeIn_WithLinearFormula() public {
        checkExactInExactOutSymmetry(
            linearFormula,
            100e18, // balanceIn
            200e18, // balanceOut
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }

    function test_FeeIn_WithCircularFormula() public {
        checkExactInExactOutSymmetry(
            circularFormula,
            100e18, // balanceIn
            500e18, // balanceOut
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }

    function test_FeeIn_WithConstantSumFormula() public {
        checkExactInExactOutSymmetry(
            constantSumFormula,
            100e18, // balanceIn
            500e18, // balanceOut
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }


    function test_FeeIn_WithSmoothTransitionFormula() public {
        checkExactInExactOutSymmetry(
            smoothTransitionFormula,
            100e18, // balanceIn
            500e18, // balanceOut (use larger pool for smooth transition)
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }

    function test_FeeOut_WithXYCFormula() public {
        checkExactInExactOutSymmetry(
            xycFormula,
            100e18, // balanceIn
            200e18, // balanceOut
            0.03e9, // 3% fee
            false // isFeeIn
        );
    }

    function test_FeeOut_WithLinearFormula() public {
        checkExactInExactOutSymmetry(
            linearFormula,
            100e18, // balanceIn
            200e18, // balanceOut
            0.03e9, // 3% fee
            false // isFeeIn
        );
    }

    function test_FeeOut_WithCircularFormula() public {
        checkExactInExactOutSymmetry(
            circularFormula,
            100e18, // balanceIn
            500e18, // balanceOut
            0.03e9, // 3% fee
            false // isFeeIn
        );
    }

    function test_FeeOut_WithConstantSumFormula() public {
        checkExactInExactOutSymmetry(
            constantSumFormula,
            100e18, // balanceIn
            500e18, // balanceOut (use larger pool for constant sum)
            0.03e9, // 3% fee
            false // isFeeIn
        );
    }


    function test_FeeOut_WithSmoothTransitionFormula() public {
        checkExactInExactOutSymmetry(
            smoothTransitionFormula,
            100e18, // balanceIn
            700e18, // balanceOut (use larger pool for smooth transition)
            0.03e9, // 3% fee
            false // isFeeIn
        );
    }

    function test_FeeIn_WithInverseFormula() public {
        checkExactInExactOutSymmetry(
            inverseFormula,
            100e18, // balanceIn
            100e18, // balanceOut
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }

    function test_FeeOut_WithInverseFormula() public {
        checkExactInExactOutSymmetry(
            inverseFormula,
            100e18, // balanceIn
            300e18, // balanceOut
            0.03e9, // 3% fee
            false // isFeeOut
        );
    }

    function test_FeeIn_WithHyperbolicFormula() public {
        checkExactInExactOutSymmetry(
            hyperbolicFormula,
            100e18, // balanceIn
            100e18, // balanceOut
            0.03e9, // 3% fee
            true // isFeeIn
        );
    }

    function test_FeeOut_WithHyperbolicFormula() public {
        checkExactInExactOutSymmetry(
            hyperbolicFormula,
            100e18, // balanceIn
            100e18, // balanceOut
            0.03e9, // 3% fee
            false // isFeeOut
        );
    }

    // === SWAP FORMULAS ===

    /**
     * @notice Standard XYC formula: x * y = k
     */
    function xycFormula(Context memory ctx, bytes calldata) internal pure {
        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "XYC: amountOut should be 0 for exactIn");
            ctx.swap.amountOut = (ctx.swap.amountIn * ctx.swap.balanceOut) /
                                (ctx.swap.balanceIn + ctx.swap.amountIn);
        } else {
            require(ctx.swap.amountIn == 0, "XYC: amountIn should be 0 for exactOut");
            ctx.swap.amountIn = Math.ceilDiv(
                ctx.swap.amountOut * ctx.swap.balanceIn,
                ctx.swap.balanceOut - ctx.swap.amountOut
            );
        }
    }

    /**
     * @notice Linear formula: fixed exchange rate
     * @dev Uses rate of balanceOut/balanceIn as price
     */
    function linearFormula(Context memory ctx, bytes calldata) internal pure {
        uint256 price = ctx.swap.balanceOut * ONE / ctx.swap.balanceIn; // price in 1e18 precision

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "Linear: amountOut should be 0 for exactIn");
            ctx.swap.amountOut = ctx.swap.amountIn * price / ONE;
        } else {
            require(ctx.swap.amountIn == 0, "Linear: amountIn should be 0 for exactOut");
            ctx.swap.amountIn = Math.ceilDiv(ctx.swap.amountOut * ONE, price);
        }
    }

    /**
     * @notice Circular formula: x² + y² = k²
     * @dev Non-linear formula that maintains circular invariant
     */
    function circularFormula(Context memory ctx, bytes calldata) internal pure {
        uint256 k2 = ctx.swap.balanceIn * ctx.swap.balanceIn +
                     ctx.swap.balanceOut * ctx.swap.balanceOut;

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "Circular: amountOut should be 0 for exactIn");
            uint256 newBalanceIn = ctx.swap.balanceIn + ctx.swap.amountIn;
            require(newBalanceIn * newBalanceIn < k2, "Circular: Would exceed invariant");
            ctx.swap.amountOut = ctx.swap.balanceOut - Math.sqrt(k2 - newBalanceIn * newBalanceIn);
        } else {
            require(ctx.swap.amountIn == 0, "Circular: amountIn should be 0 for exactOut");
            uint256 newBalanceOut = ctx.swap.balanceOut - ctx.swap.amountOut;
            require(newBalanceOut * newBalanceOut < k2, "Circular: Would exceed invariant");
            ctx.swap.amountIn = Math.sqrt(k2 - newBalanceOut * newBalanceOut) - ctx.swap.balanceIn;
        }
    }

    /**
     * @notice Constant sum formula: x + y = k
     */
    function constantSumFormula(Context memory ctx, bytes calldata) internal pure {
        // For constant sum, the exchange rate is always 1:1
        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "ConstantSum: amountOut should be 0 for exactIn");
            ctx.swap.amountOut = ctx.swap.amountIn;
            require(ctx.swap.amountOut <= ctx.swap.balanceOut, "ConstantSum: Insufficient balanceOut");
        } else {
            require(ctx.swap.amountIn == 0, "ConstantSum: amountIn should be 0 for exactOut");
            ctx.swap.amountIn = ctx.swap.amountOut;
        }
    }


    /**
     * @notice Harmonic mean style formula: 2xy/(x+y) = k
     */
    function smoothTransitionFormula(Context memory ctx, bytes calldata) internal pure {
        // k = 2 * balanceIn * balanceOut / (balanceIn + balanceOut)
        uint256 k = 2 * ctx.swap.balanceIn * ctx.swap.balanceOut / (ctx.swap.balanceIn + ctx.swap.balanceOut);

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "SmoothTransition: amountOut should be 0 for exactIn");
            uint256 newBalanceIn = ctx.swap.balanceIn + ctx.swap.amountIn;

            // Solve for newBalanceOut: 2 * newBalanceIn * newBalanceOut / (newBalanceIn + newBalanceOut) = k
            // This gives: newBalanceOut = k * newBalanceIn / (2 * newBalanceIn - k)
            uint256 newBalanceOut = k * newBalanceIn / (2 * newBalanceIn - k);
            ctx.swap.amountOut = ctx.swap.balanceOut - newBalanceOut;
        } else {
            require(ctx.swap.amountIn == 0, "SmoothTransition: amountIn should be 0 for exactOut");
            uint256 newBalanceOut = ctx.swap.balanceOut - ctx.swap.amountOut;

            // Solve for newBalanceIn: 2 * newBalanceIn * newBalanceOut / (newBalanceIn + newBalanceOut) = k
            // This gives: newBalanceIn = k * newBalanceOut / (2 * newBalanceOut - k)
            uint256 newBalanceIn = Math.ceilDiv(k * newBalanceOut, 2 * newBalanceOut - k);
            ctx.swap.amountIn = newBalanceIn - ctx.swap.balanceIn;
        }
    }

    /**
     * @notice Inverse formula: 1/x + 1/y = k
     */
    function inverseFormula(Context memory ctx, bytes calldata) internal pure {
        // k = 1/balanceIn + 1/balanceOut
        uint256 k = (ONE * ctx.swap.balanceOut + ONE * ctx.swap.balanceIn) * ONE / (ctx.swap.balanceIn * ctx.swap.balanceOut);

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "Inverse: amountOut should be 0 for exactIn");
            uint256 newBalanceIn = ctx.swap.balanceIn + ctx.swap.amountIn;

            // 1/newBalanceIn + 1/newBalanceOut = k
            // 1/newBalanceOut = k - 1/newBalanceIn
            // newBalanceOut = 1 / (k - 1/newBalanceIn)
            uint256 newInverseOut = k - ONE * ONE / newBalanceIn;
            require(newInverseOut > 0, "Inverse: Would result in negative balance");
            uint256 newBalanceOut = ONE * ONE / newInverseOut;
            ctx.swap.amountOut = ctx.swap.balanceOut - newBalanceOut;
        } else {
            require(ctx.swap.amountIn == 0, "Inverse: amountIn should be 0 for exactOut");
            uint256 newBalanceOut = ctx.swap.balanceOut - ctx.swap.amountOut;

            // 1/newBalanceIn + 1/newBalanceOut = k
            // 1/newBalanceIn = k - 1/newBalanceOut
            // newBalanceIn = 1 / (k - 1/newBalanceOut)
            uint256 newInverseIn = k - ONE * ONE / newBalanceOut;
            require(newInverseIn > 0, "Inverse: Would result in negative balance");
            uint256 newBalanceIn = Math.ceilDiv(ONE * ONE, newInverseIn);
            ctx.swap.amountIn = newBalanceIn - ctx.swap.balanceIn;
        }
    }

    /**
     * @notice Hyperbolic formula: x/y + y/x = k
     * @dev For balanced pools where x=y, k=2. This is a special case that simplifies calculations.
     */
    function hyperbolicFormula(Context memory ctx, bytes calldata) internal pure {
        // For simplicity and to avoid overflow, we'll implement this for balanced pools only
        // where balanceIn = balanceOut, which gives us k = 2
        require(ctx.swap.balanceIn == ctx.swap.balanceOut, "Hyperbolic: Only balanced pools supported");

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, "Hyperbolic: amountOut should be 0 for exactIn");

            // For this simplified hyperbolic formula, we'll use a modified constant product approach
            // that maintains the spirit of x/y + y/x = k but ensures valid swaps
            // We'll use: amountOut = amountIn * balance / (balance + 2*amountIn)
            // This gives diminishing returns as trade size increases

            uint256 balance = ctx.swap.balanceIn; // Same as balanceOut for balanced pools
            ctx.swap.amountOut = ctx.swap.amountIn * balance / (balance + 2 * ctx.swap.amountIn);
        } else {
            require(ctx.swap.amountIn == 0, "Hyperbolic: amountIn should be 0 for exactOut");

            // For exactOut: amountIn = amountOut * balance / (balance - 2*amountOut)
            uint256 balance = ctx.swap.balanceOut; // Same as balanceIn for balanced pools
            require(2 * ctx.swap.amountOut < balance, "Hyperbolic: Amount too large");

            ctx.swap.amountIn = Math.ceilDiv(
                ctx.swap.amountOut * balance,
                balance - 2 * ctx.swap.amountOut
            );
        }
    }
}
