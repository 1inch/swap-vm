// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
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
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { MinRateArgsBuilder } from "../src/instructions/MinRate.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title MinRateTest
 * @notice Functional tests for MinRate instruction
 * @dev Tests minimum rate enforcement and adjustment mechanics
 */
contract MinRateTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * Test requireMinRate with passing rate
     */
    function test_RequireMinRatePass() public {
        // Setup: 1 tokenA = 2 tokenB base rate
        // MinRate: require at most 1 tokenA : 2.2 tokenB (maker protection)
        uint64 rateA = 1e18;
        uint64 rateB = 2.2e18;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(200e18)])
                )),
            program.build(_requireMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Should succeed - rate is 2:1 which doesn't exceed the max 1:2.2
        uint256 amountOut = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );

        assertEq(amountOut, 2e18, "Should get base rate output");
    }

    /**
     * Test requireMinRate with failing rate
     */
    function test_RequireMinRateRevert() public {
        // Setup: 1 tokenA = 2 tokenB base rate
        // MinRate: require at most 1 tokenA : 1.5 tokenB (maker protection)
        uint64 rateA = 1e18;
        uint64 rateB = 1.5e18;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(200e18)])
                )),
            program.build(_requireMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Mock the input tokens
        TokenMock(address(tokenA)).mint(taker, 1e18);

        // Should revert - rate is 2:1 which exceeds the max 1:1.5
        vm.expectRevert();
        swapVM.swap(
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );
    }

    /**
     * Test adjustMinRate caps output when rate is too good
     */
    function test_AdjustMinRateCapsOutput() public {
        // Setup: 1 tokenA = 3 tokenB base rate
        // MinRate adjust: cap at most 1 tokenA = 2 tokenB (protect maker)
        uint64 rateA = 1e18;
        uint64 rateB = 2e18;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(300e18)])
                )),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Execute swap - output should be capped to protect maker
        uint256 amountOut = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );

        assertEq(amountOut, 2e18, "Should cap output at min rate");
    }

    /**
     * Test adjustMinRate with exactOut mode
     */
    function test_AdjustMinRateExactOut() public {
        // Setup: 1 tokenA = 3 tokenB base rate
        // MinRate adjust: cap at most 1 tokenA = 2 tokenB (protect maker)
        uint64 rateA = 1e18;
        uint64 rateB = 2e18;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(300e18)])
                )),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactOutData = _signAndPackTakerData(order, false, 10e18); // Want 10 tokenB

        // Quote required input
        (uint256 quotedIn,,) = swapVM.asView().quote(
            order,
            address(tokenA),
            address(tokenB),
            10e18,
            exactOutData
        );

        // Should require more input due to min rate cap
        assertEq(quotedIn, 5e18, "Should require exactly 5 tokenA for 10 tokenB");
    }

    /**
     * Test MinRate with fees
     */
    function test_MinRateWithFees() public {
        // Base rate: 1 tokenA = 2 tokenB
        // Fee: 1% on output
        // MinRate: cap at 1:1.9 (protect maker from giving too much after fees)
        uint64 rateA = 1e18;
        uint64 rateB = 1.9e18;
        uint32 feeBps = 0.01e9; // 1% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(200e18)])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256 amountOut = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );

        // Should get capped rate after fees
        // Base would give 2e18, minus 1% fee = 1.98e18
        // But MinRate caps at 1.9e18, minus 1% fee = 1.881e18
        assertEq(amountOut, 1.881e18, "Should get min rate minus fee");
    }

    /**
     * Test MinRate doesn't affect worse rates
     */
    function test_MinRateNoEffectOnWorseRates() public {
        // Setup: 1 tokenA = 1.5 tokenB base rate (worse than min)
        // MinRate: cap at most 1 tokenA = 2 tokenB
        uint64 rateA = 1e18;
        uint64 rateB = 2e18;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(150e18)])
                )),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256 amountOut = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );

        // Should get base rate (1.5:1) as it's worse than min rate (2:1)
        assertEq(amountOut, 1.5e18, "Should get base rate when worse than min");
    }

    /**
     * Test MinRate with different token orderings
     */
    function test_MinRateTokenOrdering() public {
        // Test both A->B and B->A with same min rate
        // MinRate: 2 tokenA = 1 tokenB (cap rate to protect maker)
        uint64 rateA = 2e18;
        uint64 rateB = 1e18;

        // First test A -> B
        // Base rate: 1 tokenA = 0.5 tokenB (200:100)
        // This equals the min rate, so no adjustment
        Program memory programAtoB = ProgramBuilder.init(_opcodes());
        bytes memory bytecodeAtoB = bytes.concat(
            programAtoB.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(200e18), uint256(100e18)])
                )),
            programAtoB.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            programAtoB.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory orderAtoB = _createOrder(bytecodeAtoB);
        bytes memory exactInDataAtoB = _signAndPackTakerData(orderAtoB, true, 0);

        uint256 amountOutAtoB = _executeSwap(
            swapVM,
            orderAtoB,
            address(tokenA),
            address(tokenB),
            2e18, // 2 tokenA
            exactInDataAtoB
        );

        assertEq(amountOutAtoB, 1e18, "Should get 1 tokenB for 2 tokenA");

        // Now test B -> A with same balances
        // Base rate: 1 tokenB = 2 tokenA
        // This equals the inverse of min rate, so no adjustment
        Program memory programBtoA = ProgramBuilder.init(_opcodes());
        bytes memory bytecodeBtoA = bytes.concat(
            programBtoA.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(200e18), uint256(100e18)])
                )),
            programBtoA.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            programBtoA.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
        );

        ISwapVM.Order memory orderBtoA = _createOrder(bytecodeBtoA);
        bytes memory exactInDataBtoA = _signAndPackTakerData(orderBtoA, true, 0);

        uint256 amountOutBtoA = _executeSwap(
            swapVM,
            orderBtoA,
            address(tokenB),
            address(tokenA),
            1e18, // 1 tokenB
            exactInDataBtoA
        );

        assertEq(amountOutBtoA, 2e18, "Should get 2 tokenA for 1 tokenB");
    }

    /**
     * Test extreme min rates
     */
    function test_MinRateExtreme() public {
        // Very high cap: at most 1 tokenA = 1000 tokenB
        // Base rate: 1 tokenA = 10000 tokenB (would be too generous)
        uint64 rateA = 1e9;
        uint64 rateB = 1000e9;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(1000000e18)])
                )),
            program.build(_adjustMinRate1D,
                MinRateArgsBuilder.build(address(tokenA), address(tokenB), rateA, rateB)),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256 amountOut = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );

        // Should be capped at min rate
        assertEq(amountOut, 1000e18, "Should cap at extreme min rate");
    }

    // Helper functions
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        // Verify the swap consumed the expected input amount
        require(actualIn == amount, "Unexpected input amount consumed");

        return actualOut;
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
}
