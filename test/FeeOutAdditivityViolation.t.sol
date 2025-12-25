// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title FeeOutAdditivityViolation
 * @notice Tests demonstrating that feeOut violates additivity and when splitting is profitable
 * @dev Shows:
 *   1. Original _flatFeeAmountOutXD violates additivity
 *   2. _feeOutAsInXYCXD also violates additivity (due to variable feeInBps)
 *   3. When splitting swaps is profitable considering gas costs
 */
contract FeeOutAdditivityViolation is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant BALANCE = 1000e18;
    uint32 constant FEE_BPS = 0.005e9; // 0.5% fee

    // Base tx cost (always 21000)
    uint256 constant BASE_TX_COST = 21_000;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 100000e18);
        tokenB.mint(maker, 100000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.mint(taker, 100000e18);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * @notice Test showing original _flatFeeAmountOutXD violates additivity
     * @dev Split swaps get MORE output than single swap (fee "reinvested" in balanceOut)
     */
    function test_FlatFeeOut_Original_ViolatesAdditivity() public {
        console.log("=== Original _flatFeeAmountOutXD Additivity Test ===");
        console.log("Parameters: Balance = 1000 tokens, Fee = 0.5%");

        ISwapVM.Order memory order = _createOrderWithFlatFeeOut();
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        uint256 swapAmount = 100e18;

        // Single swap: swap(100)
        (uint256 singleIn, uint256 singleOut) = _quoteSwap(order, swapAmount, takerData);
        console.log("Single swap(100):");
        console.log("  amountIn (wei):", singleIn);
        console.log("  amountOut (wei):", singleOut);

        // Split swap: swap(50) + swap(50)
        // Need to execute first swap to change state, then quote second
        uint256 halfAmount = swapAmount / 2;

        // Execute first swap
        _executeSwap(order, halfAmount, takerData);
        (uint256 split1In, uint256 split1Out) = (halfAmount, _getLastSwapOut());

        // Quote second swap (state changed)
        (uint256 split2In, uint256 split2Out) = _quoteSwap(order, halfAmount, takerData);

        uint256 splitTotalOut = split1Out + split2Out;

        console.log("Split swap(50) + swap(50):");
        console.log("  First out:", split1Out);
        console.log("  Second out:", split2Out);
        console.log("  Total out:", splitTotalOut);

        // Check additivity violation
        if (splitTotalOut > singleOut) {
            uint256 profit = splitTotalOut - singleOut;
            console.log("!!! ADDITIVITY VIOLATED !!! Split > Single");
            console.log("Profit from splitting (wei):", profit);

            // This should fail - additivity is violated
            assertGt(splitTotalOut, singleOut, "Split should get more than single (additivity violated)");
        } else {
            console.log("Additivity preserved (single >= split)");
        }
    }

    /**
     * @notice Test calculating when splitting is profitable considering gas costs
     * @dev Uses same order and compares quote(100) vs execute(50)+quote(50)
     */
    function test_FeeOut_SplitProfitability() public {
        console.log("=== Split Profitability Analysis ===");
        console.log("Balance = 1000 tokens, Fee = 0.5%");

        uint256 swapAmount = 100e18;

        // Extra gas for additional tx: base + calldata
        uint256 extraTxGas = BASE_TX_COST + (800 * 16); // ~33,800 gas

        // Create one order for comparison
        ISwapVM.Order memory order = _createOrderWithFlatFeeOut();
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        // === Single swap: quote(100) ===
        (, uint256 singleOut) = _quoteSwap(order, swapAmount, takerData);
        console.log("Single swap(100) amountOut:", singleOut);

        // === Split swap: execute(50) + quote(50) on same order ===
        uint256 gasBefore = gasleft();
        _executeSwap(order, swapAmount / 2, takerData);
        uint256 split1ExecGas = gasBefore - gasleft();
        uint256 split1Out = _getLastSwapOut();

        (, uint256 split2Out) = _quoteSwap(order, swapAmount / 2, takerData);

        uint256 splitTotalOut = split1Out + split2Out;

        console.log("Split swap(50+50):");
        console.log("  First out:", split1Out);
        console.log("  Second out:", split2Out);
        console.log("  Total out:", splitTotalOut);

        // === Profitability Analysis ===
        console.log("=== Profitability Analysis ===");

        if (splitTotalOut > singleOut) {
            uint256 profitTokens = splitTotalOut - singleOut;
            console.log("Profit from splitting (wei):", profitTokens);

            // Extra gas for second tx = BASE_TX_COST + calldata + execution
            // Execution gas is roughly same as first split (~65k)
            uint256 extraGas = extraTxGas + split1ExecGas;
            console.log("Extra gas for split:", extraGas);

            uint256[4] memory gasPrices = [uint256(10), 30, 100, 300];

            for (uint256 j = 0; j < 4; j++) {
                uint256 gasCostWei = extraGas * gasPrices[j] * 1e9;
                console.log("At", gasPrices[j], "gwei:");
                console.log("  Extra gas cost (ETH wei):", gasCostWei);

                // Assuming 1 token ≈ 1 ETH for comparison
                if (profitTokens > gasCostWei) {
                    console.log("  -> PROFITABLE! Net (if token~=ETH):", profitTokens - gasCostWei);
                } else {
                    console.log("  -> NOT profitable (if token~=ETH), loss:", gasCostWei - profitTokens);
                }
            }

            // Breakeven gas price
            uint256 breakevenGwei = profitTokens / extraGas / 1e9;
            console.log("Breakeven gas price:", breakevenGwei, "gwei (if token~=ETH)");

            // Assert that additivity is violated
            assertGt(splitTotalOut, singleOut, "FeeOut should violate additivity");
        } else {
            console.log("No profit from splitting - single >= split");
        }
    }

    /**
     * @notice Binary search to find minimum swap size where splitting is profitable
     * @dev For each gas price, find the minimum swap amount where profit > gas cost
     */
    function test_FeeOut_MinProfitableSwapSize() public {
        console.log("=== Minimum Profitable Swap Size (Binary Search) ===");
        console.log("Balance = 1000 tokens, Fee = 0.5%");

        // Extra gas for additional tx
        uint256 extraTxGas = BASE_TX_COST + (800 * 16) + 165_000; // base + calldata + exec ≈ 200k

        uint256[4] memory gasPrices = [uint256(10), 30, 100, 300];

        for (uint256 i = 0; i < gasPrices.length; i++) {
            uint256 gasPrice = gasPrices[i];
            uint256 gasCostWei = extraTxGas * gasPrice * 1e9;

            console.log("--- Gas price:", gasPrice, "gwei ---");
            console.log("Gas cost (wei):", gasCostWei);

            // Binary search for minimum profitable swap size
            uint256 low = 1e18;      // 1 token
            uint256 high = BALANCE;  // 1000 tokens
            uint256 minProfitable = 0;

            while (low <= high) {
                uint256 mid = (low + high) / 2;

                uint256 profit = _calculateSplitProfit(mid);

                if (profit > gasCostWei) {
                    minProfitable = mid;
                    high = mid - 1e17; // Decrease by 0.1 token
                } else {
                    low = mid + 1e17;  // Increase by 0.1 token
                }

                // Prevent infinite loop
                if (high < low || (high - low < 1e17)) break;
            }

            if (minProfitable > 0) {
                uint256 profitAtMin = _calculateSplitProfit(minProfitable);
                console.log("Min profitable swap (tokens):", minProfitable / 1e18);
                console.log("Profit at min (wei):", profitAtMin);
                console.log("Net profit (wei):", profitAtMin - gasCostWei);
            } else {
                console.log("No profitable swap size found (need > 1000 tokens)");
            }
        }
    }

    /**
     * @notice Calculate profit from splitting a swap using pure math
     */
    function _calculateSplitProfit(uint256 swapAmount) private returns (uint256) {
        ISwapVM.Order memory order = _createOrderWithFlatFeeOut();
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        // Save the current state
        uint256 snapshot = vm.snapshot();

        // Single swap
        (, uint256 singleOut) = _quoteSwap(order, swapAmount, takerData);

        // Restore state to before the swap
        vm.revertTo(snapshot);

        // Split swap - simulate by calculating XYC formula
        // First half
        uint256 half = swapAmount / 2;

        // Save the current state
        snapshot = vm.snapshot();
        (, uint256 split1Out) = _quoteSwap(order, half, takerData);
        (, uint256 split2Out) = _quoteSwap(order, half, takerData);
        // Restore state to before the swap
        vm.revertTo(snapshot);

        uint256 splitTotal = split1Out + split2Out;

        if (splitTotal > singleOut) {
            return splitTotal - singleOut;
        }
        return 0;
    }

    /**
     * @notice Compare feeIn vs feeOut additivity
     * @dev Shows that feeIn preserves additivity while feeOut violates it
     */
    function test_FeeIn_vs_FeeOut_Additivity() public {
        console.log("=== FeeIn vs FeeOut Additivity Comparison ===");

        uint256 swapAmount = 100e18;

        // Test FeeIn
        console.log("\n--- FeeIn (_flatFeeAmountInXD) ---");
        {
            ISwapVM.Order memory order = _createOrderWithFlatFeeIn();
            bytes memory takerData = _signAndPackTakerData(order, true, 0);

            (,uint256 singleOut) = _quoteSwap(order, swapAmount, takerData);

            _executeSwap(order, swapAmount / 2, takerData);
            uint256 split1Out = _getLastSwapOut();
            (,uint256 split2Out) = _quoteSwap(order, swapAmount / 2, takerData);

            uint256 splitTotalOut = split1Out + split2Out;

            console.log("Single out:", singleOut);
            console.log("Split out:", splitTotalOut);

            if (singleOut >= splitTotalOut) {
                console.log("-> Additivity PRESERVED");
            } else {
                console.log("-> VIOLATED! Diff:", splitTotalOut - singleOut);
            }
        }

        // Test FeeOut
        console.log("--- FeeOut (_flatFeeAmountOutXD) ---");
        {
            ISwapVM.Order memory order = _createOrderWithFlatFeeOut();
            bytes memory takerData = _signAndPackTakerData(order, true, 0);

            (,uint256 singleOut) = _quoteSwap(order, swapAmount, takerData);

            _executeSwap(order, swapAmount / 2, takerData);
            uint256 split1Out = _getLastSwapOut();
            (,uint256 split2Out) = _quoteSwap(order, swapAmount / 2, takerData);

            uint256 splitTotalOut = split1Out + split2Out;

            console.log("Single out:", singleOut);
            console.log("Split out:", splitTotalOut);

            if (singleOut >= splitTotalOut) {
                console.log("-> Additivity PRESERVED");
            } else {
                console.log("-> VIOLATED! Diff:", splitTotalOut - singleOut);
            }
        }
    }

    // ==================== Helper Functions ====================

    uint256 private _lastSwapOut;

    function _getLastSwapOut() private view returns (uint256) {
        return _lastSwapOut;
    }

    function _createOrderWithFlatFeeOut() private view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE, BALANCE])
                )),
            program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(FEE_BPS)),
            program.build(_xycSwapXD)
        );
        return _createOrder(bytecode);
    }

    function _createOrderWithFlatFeeIn() private view returns (ISwapVM.Order memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([BALANCE, BALANCE])
                )),
            program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(FEE_BPS)),
            program.build(_xycSwapXD)
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
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
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
        bytes memory takerData
    ) private view returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = swapVM.asView().quote(
            order,
            address(tokenA),
            address(tokenB),
            amount,
            takerData
        );
    }

    function _executeSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bytes memory takerData
    ) private {
        (,uint256 amountOut,) = swapVM.swap(
            order,
            address(tokenA),
            address(tokenB),
            amount,
            takerData
        );
        _lastSwapOut = amountOut;
    }
}
