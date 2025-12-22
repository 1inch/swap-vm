// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant ONE = 1e18;

/**
 * @title FixedPointMath
 * @notice High-precision fixed-point math operations with 1e18 scaling
 * @dev Based on OpenZeppelin's Math.sqrt() with adaptations for fixed-point arithmetic
 */
library FixedPointMath {
    /// @notice High-precision integer square root with 1e18 fixed-point scaling
    /// @dev Computes sqrt(x) where both x and result are scaled by 1e18
    /// @dev Uses bit-shift method for optimal initial guess and 7 Newton iterations
    /// @param x Value to take square root of (scaled by 1e18)
    /// @return y Square root of x (scaled by 1e18)
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) {
            return 0;
        }
        if (x == ONE) {
            return ONE; // sqrt(1e18) = 1e18
        }

        unchecked {
            // We compute: y = sqrt(x) * 1e9 (since sqrt(1e18) = 1e9)
            // This maintains 1e18 scale: if x = n * 1e18, then y = sqrt(n) * 1e18

            // Step 1: Find good initial estimate using bit-shifts (OpenZeppelin method)
            // This finds the smallest power of 2 greater than sqrt(x)
            uint256 xn = 1;
            uint256 aa = x;

            if (aa >= (1 << 128)) {
                aa >>= 128;
                xn <<= 64;
            }
            if (aa >= (1 << 64)) {
                aa >>= 64;
                xn <<= 32;
            }
            if (aa >= (1 << 32)) {
                aa >>= 32;
                xn <<= 16;
            }
            if (aa >= (1 << 16)) {
                aa >>= 16;
                xn <<= 8;
            }
            if (aa >= (1 << 8)) {
                aa >>= 8;
                xn <<= 4;
            }
            if (aa >= (1 << 4)) {
                aa >>= 4;
                xn <<= 2;
            }
            if (aa >= (1 << 2)) {
                xn <<= 1;
            }

            // Refine estimate to middle of interval (reduces error by half)
            xn = (3 * xn) >> 1;

            // Step 2: Newton iterations (7 iterations for guaranteed convergence to floor)
            // Each iteration: xn = (xn + x / xn) / 2
            // Converges quadratically
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;
            xn = (xn + x / xn) >> 1;

            // Step 3: Final correction (ensure we have floor(sqrt(x)))
            y = xn - (xn > x / xn ? 1 : 0);

            // Step 4: Scale to 1e18 (multiply by 1e9 since sqrt(1e18) = 1e9)
            y = y * 1e9;
        }
    }
}

/**
 * @title XYCConcentratedSwapArgsBuilder
 * @notice Library for building and parsing XYCConcentratedSwap instruction arguments
 * @dev Uses sqrt(price) parameterization to minimize precision-losing operations at runtime
 */
library XYCConcentratedSwapArgsBuilder {
    using SafeCast for uint256;
    using Calldata for bytes;

    error InconsistentPrices(uint256 price, uint256 priceMin, uint256 priceMax);
    error ParsingMissingSqrtPriceMin();
    error ParsingMissingSqrtPriceMax();
    error ParsingMissingInitialSqrtPrice();
    error ParsingMissingInitialLiquidity();
    error ParsingMissingInitialBalanceA();
    error ParsingMissingInitialBalanceB();
    error ParsingMissingFeeBps();
    error FeeBpsOutOfRange(uint32 feeBps);

    uint256 private constant BPS = 1e9; // Basis points: 1e9 = 100%

    /**
     * @notice Compute all parameters for concentrated swap from user-friendly inputs
     * @dev Pre-computes sqrt values to avoid runtime sqrt operations
     * @param balanceA Initial real balance of tokenA
     * @param balanceB Initial real balance of tokenB
     * @param price Current price (tokenB/tokenA with 1e18 precision)
     * @param priceMin Minimum price for concentration range
     * @param priceMax Maximum price for concentration range
     * @return sqrtPriceMin sqrt(priceMin) with 1e18 precision
     * @return sqrtPriceMax sqrt(priceMax) with 1e18 precision
     * @return sqrtPrice sqrt(price) with 1e18 precision
     * @return liquidity L = sqrt(virtualX * virtualY)
     */
    function computeParams(
        uint256 balanceA,
        uint256 balanceB,
        uint256 price,
        uint256 priceMin,
        uint256 priceMax
    ) public pure returns (
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 sqrtPrice,
        uint256 liquidity
    ) {
        require(priceMin <= price && price <= priceMax, InconsistentPrices(price, priceMin, priceMax));

        // Pre-compute sqrt values using high-precision fixed-point sqrt
        // For price with 1e18 precision, sqrtPrice should also have 1e18 precision
        // FixedPointMath.sqrt handles the 1e18 scaling internally
        sqrtPriceMin = FixedPointMath.sqrt(priceMin);
        sqrtPriceMax = FixedPointMath.sqrt(priceMax);
        sqrtPrice = FixedPointMath.sqrt(price);

        // Compute virtual reserves from real reserves and price bounds
        // virtualA = realA + L / sqrtPrice - L / sqrtPriceMax
        // virtualB = realB + L * sqrtPrice - L * sqrtPriceMin
        //
        // From Uniswap v3 math:
        // L = realA * sqrtPrice * sqrtPriceMax / (sqrtPriceMax - sqrtPrice)
        // L = realB / (sqrtPrice - sqrtPriceMin)
        //
        // We use the geometric mean approach for a balanced position:
        // virtualA = realA * sqrtPriceMax / (sqrtPriceMax - sqrtPrice)  [when sqrtPrice < sqrtPriceMax]
        // virtualB = realB * sqrtPrice / (sqrtPrice - sqrtPriceMin)     [when sqrtPrice > sqrtPriceMin]

        uint256 virtualA;
        uint256 virtualB;

        if (sqrtPrice == sqrtPriceMax) {
            // At upper bound: all liquidity is in tokenB
            virtualA = balanceA; // No virtual addition needed
            virtualB = balanceB * sqrtPrice / (sqrtPrice - sqrtPriceMin);
        } else if (sqrtPrice == sqrtPriceMin) {
            // At lower bound: all liquidity is in tokenA
            virtualA = balanceA * sqrtPriceMax / (sqrtPriceMax - sqrtPrice);
            virtualB = balanceB; // No virtual addition needed
        } else {
            // In range: compute from both sides
            virtualA = balanceA * sqrtPriceMax / (sqrtPriceMax - sqrtPrice);
            virtualB = balanceB * sqrtPrice / (sqrtPrice - sqrtPriceMin);
        }

        // L = sqrt(virtualA * virtualB)
        liquidity = Math.sqrt(virtualA * virtualB);
    }

    /**
     * @notice Build encoded arguments for 2D variant (two tokens)
     * @param sqrtPriceMin sqrt of minimum price (1e18 precision)
     * @param sqrtPriceMax sqrt of maximum price (1e18 precision)
     * @param initialSqrtPrice initial sqrt of current price (1e18 precision)
     * @param initialLiquidity initial liquidity L
     * @param initialBalanceA initial real balance of tokenA
     * @param initialBalanceB initial real balance of tokenB
     * @param feeBps Fee in basis points (1e9 = 100%), 0 for no fee
     */
    function build2D(
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 initialSqrtPrice,
        uint256 initialLiquidity,
        uint256 initialBalanceA,
        uint256 initialBalanceB,
        uint32 feeBps
    ) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(
            sqrtPriceMin,
            sqrtPriceMax,
            initialSqrtPrice,
            initialLiquidity,
            initialBalanceA,
            initialBalanceB,
            feeBps
        );
    }

    /**
     * @notice Parse encoded arguments for 2D variant
     */
    function parse2D(bytes calldata args) internal pure returns (
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 initialSqrtPrice,
        uint256 initialLiquidity,
        uint256 initialBalanceA,
        uint256 initialBalanceB,
        uint32 feeBps
    ) {
        sqrtPriceMin = uint256(bytes32(args.slice(0, 32, ParsingMissingSqrtPriceMin.selector)));
        sqrtPriceMax = uint256(bytes32(args.slice(32, 64, ParsingMissingSqrtPriceMax.selector)));
        initialSqrtPrice = uint256(bytes32(args.slice(64, 96, ParsingMissingInitialSqrtPrice.selector)));
        initialLiquidity = uint256(bytes32(args.slice(96, 128, ParsingMissingInitialLiquidity.selector)));
        initialBalanceA = uint256(bytes32(args.slice(128, 160, ParsingMissingInitialBalanceA.selector)));
        initialBalanceB = uint256(bytes32(args.slice(160, 192, ParsingMissingInitialBalanceB.selector)));
        feeBps = uint32(bytes4(args.slice(192, 196, ParsingMissingFeeBps.selector)));
    }
}

/**
 * @title XYCConcentratedSwap
 * @notice Unified concentrated liquidity swap instruction with integrated fees
 * @dev Combines balance tracking, concentration, swap, and fee handling in one instruction.
 *      Uses sqrt(price) parameterization following Uniswap v3 math.
 *      Fees are taken from input and reinvested into pool balances.
 *
 *      Key advantages over separate Balances + Concentrate + Swap + Fee:
 *      - No runtime sqrt operations (pre-computed in parameters)
 *      - Only 2-3 divisions per swap (vs 4+ in separate instructions)
 *      - Explicit price bound enforcement (reverts if exceeded)
 *      - Consistent state tracking of sqrtPrice and liquidity
 *      - Fees automatically reinvested into pool reserves
 */
contract XYCConcentratedSwap {
    using SafeCast for uint256;
    using Calldata for bytes;
    using ContextLib for Context;

    uint256 private constant BPS = 1e9; // Basis points: 1e9 = 100%

    error PriceBelowMinimum(uint256 newSqrtPrice, uint256 sqrtPriceMin);
    error PriceAboveMaximum(uint256 newSqrtPrice, uint256 sqrtPriceMax);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error SwapAmountsAlreadyComputed(uint256 amountIn, uint256 amountOut);

    /// @notice Current sqrt price for each order (1e18 precision)
    mapping(bytes32 orderHash => uint256) public concentratedSqrtPrices;

    /// @notice Current liquidity for each order
    mapping(bytes32 orderHash => uint256) public concentratedLiquidities;

    /// @notice Real token balances for each order (stored as balance + 1 to distinguish from unset)
    mapping(bytes32 orderHash => mapping(address token => uint256)) public concentratedBalances;

    /**
     * @notice Get current sqrt price for an order, returns initial if not set
     */
    function getSqrtPrice(bytes32 orderHash, uint256 initialSqrtPrice) public view returns (uint256) {
        uint256 stored = concentratedSqrtPrices[orderHash];
        return stored == 0 ? initialSqrtPrice : stored;
    }

    /**
     * @notice Get current liquidity for an order, returns initial if not set
     */
    function getLiquidity(bytes32 orderHash, uint256 initialLiquidity) public view returns (uint256) {
        uint256 stored = concentratedLiquidities[orderHash];
        return stored == 0 ? initialLiquidity : stored;
    }

    /**
     * @notice Get current balance for a token in an order
     */
    function getConcentratedBalance(bytes32 orderHash, address token, uint256 initialBalance) public view returns (uint256) {
        uint256 stored = concentratedBalances[orderHash][token];
        // Use a sentinel pattern: store balance+1, return balance
        // This allows distinguishing "never set" from "set to 0"
        return stored == 0 ? initialBalance : stored - 1;
    }

    /**
     * @notice Concentrated swap instruction for 2 tokens with integrated fees
     * @dev Performs swap with concentrated liquidity, enforcing price bounds.
     *      Fees are deducted from input and reinvested into pool balances.
     *
     * Args layout (196 bytes):
     * - sqrtPriceMin (32 bytes): sqrt of minimum allowed price
     * - sqrtPriceMax (32 bytes): sqrt of maximum allowed price
     * - initialSqrtPrice (32 bytes): initial sqrt price at order creation
     * - initialLiquidity (32 bytes): initial liquidity L
     * - initialBalanceA (32 bytes): initial real balance of tokenA (lower address)
     * - initialBalanceB (32 bytes): initial real balance of tokenB (higher address)
     * - feeBps (4 bytes): fee in basis points (1e9 = 100%), 0 for no fee
     */
    function _xycConcentratedSwap2D(Context memory ctx, bytes calldata args) internal {
        require(
            ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0,
            SwapAmountsAlreadyComputed(ctx.swap.amountIn, ctx.swap.amountOut)
        );

        // Parse parameters (now includes feeBps)
        (
            uint256 sqrtPriceMin,
            uint256 sqrtPriceMax,
            uint256 initialSqrtPrice,
            uint256 initialLiquidity,
            uint256 initialBalanceA,
            uint256 initialBalanceB,
            uint32 feeBps
        ) = XYCConcentratedSwapArgsBuilder.parse2D(args);

        // Determine token ordering (A < B by address)
        (address tokenA, address tokenB) = ctx.query.tokenIn < ctx.query.tokenOut
            ? (ctx.query.tokenIn, ctx.query.tokenOut)
            : (ctx.query.tokenOut, ctx.query.tokenIn);

        bool isAtoB = ctx.query.tokenIn == tokenA;

        // Load current state
        uint256 currentSqrtPrice = getSqrtPrice(ctx.query.orderHash, initialSqrtPrice);
        uint256 L = getLiquidity(ctx.query.orderHash, initialLiquidity);

        // Load real balances
        uint256 balanceA = getConcentratedBalance(ctx.query.orderHash, tokenA, initialBalanceA);
        uint256 balanceB = getConcentratedBalance(ctx.query.orderHash, tokenB, initialBalanceB);

        // Set context balances
        ctx.swap.balanceIn = isAtoB ? balanceA : balanceB;
        ctx.swap.balanceOut = isAtoB ? balanceB : balanceA;

        uint256 newSqrtPrice;
        uint256 grossAmountIn;  // What taker pays (including fee)
        uint256 netAmountIn;    // What goes into swap math (excluding fee)

        if (ctx.query.isExactIn) {
            // ExactIn: taker specifies gross input, we compute fee and net
            grossAmountIn = ctx.swap.amountIn;

            // Compute fee (rounded up to favor maker)
            uint256 feeAmount = Math.ceilDiv(grossAmountIn * feeBps, BPS);
            netAmountIn = grossAmountIn - feeAmount;

            if (isAtoB) {
                // A -> B: price decreases (sqrtPrice decreases)
                // Use netAmountIn for price calculation
                uint256 lOverPrice = Math.mulDiv(L, ONE, currentSqrtPrice);
                uint256 denominator = lOverPrice + netAmountIn;
                newSqrtPrice = Math.mulDiv(L, ONE, denominator);

                // amountOut = L * (sqrtPrice - newSqrtPrice) / ONE
                ctx.swap.amountOut = Math.mulDiv(L, currentSqrtPrice - newSqrtPrice, ONE);

                require(newSqrtPrice >= sqrtPriceMin, PriceBelowMinimum(newSqrtPrice, sqrtPriceMin));
            } else {
                // B -> A: price increases (sqrtPrice increases)
                // Use netAmountIn for price calculation
                newSqrtPrice = currentSqrtPrice + Math.mulDiv(netAmountIn, ONE, L);

                uint256 lOverOld = Math.mulDiv(L, ONE, currentSqrtPrice);
                uint256 lOverNew = Math.mulDiv(L, ONE, newSqrtPrice);
                ctx.swap.amountOut = lOverOld - lOverNew;

                require(newSqrtPrice <= sqrtPriceMax, PriceAboveMaximum(newSqrtPrice, sqrtPriceMax));
            }
        } else {
            // ExactOut: first compute netAmountIn needed for swap, then derive grossAmountIn
            if (isAtoB) {
                // A -> B: need to output amountOut of B
                uint256 deltaPrice = Math.mulDiv(ctx.swap.amountOut, ONE, L);
                require(deltaPrice < currentSqrtPrice, InsufficientLiquidity(ctx.swap.amountOut, Math.mulDiv(L, currentSqrtPrice, ONE)));
                newSqrtPrice = currentSqrtPrice - deltaPrice;

                // netAmountIn = L/newSqrtPrice - L/sqrtPrice (ceiling)
                uint256 lOverNew = Math.mulDiv(L, ONE, newSqrtPrice);
                uint256 lOverOld = Math.mulDiv(L, ONE, currentSqrtPrice);
                netAmountIn = lOverNew - lOverOld + 1;

                require(newSqrtPrice >= sqrtPriceMin, PriceBelowMinimum(newSqrtPrice, sqrtPriceMin));
            } else {
                // B -> A: need to output amountOut of A
                uint256 lOverOld = Math.mulDiv(L, ONE, currentSqrtPrice);
                require(ctx.swap.amountOut < lOverOld, InsufficientLiquidity(ctx.swap.amountOut, lOverOld));
                uint256 lOverNew = lOverOld - ctx.swap.amountOut;
                newSqrtPrice = Math.mulDiv(L, ONE, lOverNew);

                // netAmountIn = L * (newSqrtPrice - sqrtPrice) / ONE (ceiling)
                netAmountIn = Math.ceilDiv(L * (newSqrtPrice - currentSqrtPrice), ONE);

                require(newSqrtPrice <= sqrtPriceMax, PriceAboveMaximum(newSqrtPrice, sqrtPriceMax));
            }

            // Compute grossAmountIn: netAmountIn = grossAmountIn * (1 - feeBps/BPS)
            // So: grossAmountIn = netAmountIn * BPS / (BPS - feeBps)
            if (feeBps > 0) {
                grossAmountIn = Math.ceilDiv(netAmountIn * BPS, BPS - feeBps);
            } else {
                grossAmountIn = netAmountIn;
            }
            ctx.swap.amountIn = grossAmountIn;  // Taker pays GROSS
        }

        // Verify sufficient real balance for output
        require(ctx.swap.amountOut <= ctx.swap.balanceOut, InsufficientLiquidity(ctx.swap.amountOut, ctx.swap.balanceOut));

        // Update state (only in non-static context)
        if (!ctx.vm.isStaticContext) {
            concentratedSqrtPrices[ctx.query.orderHash] = newSqrtPrice;
            concentratedLiquidities[ctx.query.orderHash] = L;

            // KEY: Store GROSS amounts (fee reinvested into pool balances)
            // This means fees accumulate in the pool and increase available liquidity
            if (isAtoB) {
                concentratedBalances[ctx.query.orderHash][tokenA] = balanceA + grossAmountIn + 1;
                concentratedBalances[ctx.query.orderHash][tokenB] = balanceB - ctx.swap.amountOut + 1;
            } else {
                concentratedBalances[ctx.query.orderHash][tokenB] = balanceB + grossAmountIn + 1;
                concentratedBalances[ctx.query.orderHash][tokenA] = balanceA - ctx.swap.amountOut + 1;
            }
        }
    }
}

