// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { ControlsArgsBuilder } from "../src/instructions/Controls.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { dynamic } from "./utils/Dynamic.sol";


/**
 * @title Controls
 * @notice Tests for Controls instruction opcodes
 * @dev Tests control flow, conditional execution, and validation in swap programs
 */
contract ControlsTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    TokenMock public tokenC;

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
        tokenC = new TokenMock("Token C", "TKC");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        tokenC.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenC.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenC.approve(address(swapVM), type(uint256).max);
    }

    /**
     * Test salt instruction for order uniqueness
     */
    function test_Salt() public {
        uint64 salt1 = 12345;
        uint64 salt2 = 67890;

        bytes memory bytecode1 = _buildSimpleSwapWithSalt(salt1);
        bytes memory bytecode2 = _buildSimpleSwapWithSalt(salt2);

        ISwapVM.Order memory order1 = _createOrder(bytecode1);
        ISwapVM.Order memory order2 = _createOrder(bytecode2);

        // Order hashes should be different
        assertNotEq(swapVM.hash(order1), swapVM.hash(order2), "Different salts = different hashes");

        // Both orders should execute successfully
        _executeSwap(order1, address(tokenA), address(tokenB), 1e18);
        _executeSwap(order2, address(tokenA), address(tokenB), 1e18);
    }

    /**
     * Test deadline control
     */
    function test_Deadline() public {
        uint40 deadline = uint40(block.timestamp + 1 hours);

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_deadline, ControlsArgsBuilder.buildDeadline(deadline)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Should work before deadline
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertGt(amountOut, 0, "Works before deadline");

        // Advance past deadline
        vm.warp(deadline + 1);

        // Should fail after deadline
        bytes memory takerData = _signAndPackTakerData(order, true, 0);
        tokenA.mint(taker, 1e18);
        vm.expectRevert(abi.encodeWithSelector(DeadlineReached.selector, taker, deadline));
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);
    }

    /**
     * Test onlyTakerTokenBalanceNonZero
     */
    function test_OnlyTakerTokenBalanceNonZero() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            // Require taker holds tokenC
            program.build(_onlyTakerTokenBalanceNonZero,
                ControlsArgsBuilder.buildTakerTokenBalanceNonZero(address(tokenC))),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        // Should fail without tokenC
        tokenA.mint(taker, 1e18);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTokenBalanceIsZero.selector,
            taker,
            address(tokenC)
        ));
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);

        // Give taker 1 wei of tokenC
        tokenC.mint(taker, 1);

        // Should work now
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertGt(amountOut, 0, "Works with tokenC balance");
    }

    /**
     * Test onlyTakerTokenBalanceGte
     */
    function test_OnlyTakerTokenBalanceGte() public {
        uint256 minBalance = 1000e18;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_onlyTakerTokenBalanceGte,
                ControlsArgsBuilder.buildTakerTokenBalanceGte(address(tokenC), minBalance)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        // Should fail with insufficient balance
        tokenC.mint(taker, 999e18);
        tokenA.mint(taker, 1e18);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTokenBalanceIsLessThatRequired.selector,
            taker,
            address(tokenC),
            999e18,
            minBalance
        ));
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);

        // Add 1e18 more to reach minimum
        tokenC.mint(taker, 1e18);

        // Should work now
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertGt(amountOut, 0, "Works with sufficient balance");
    }

    /**
     * Test onlyTakerTokenSupplyShareGte
     */
    function test_OnlyTakerTokenSupplyShareGte() public {
        uint64 minShareE18 = 0.1e18; // 10% of supply

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_onlyTakerTokenSupplyShareGte,
                ControlsArgsBuilder.buildTakerTokenSupplyShareGte(address(tokenC), minShareE18)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        // Maker has 10000e18, taker needs 10% of total
        tokenC.mint(taker, 1000e18); // 9.09% of 11000e18

        // Should fail with insufficient share
        tokenA.mint(taker, 1e18);
        vm.expectRevert(abi.encodeWithSelector(
            TakerTokenBalanceSupplyShareIsLessThatRequired.selector,
            taker,
            address(tokenC),
            1000e18,
            tokenC.totalSupply(),
            minShareE18
        ));
        swapVM.swap(order, address(tokenA), address(tokenB), 1e18, takerData);

        // Increase share to > 10%
        tokenC.mint(taker, 200e18); // Now 10.9% of 11200e18

        // Should work now
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertGt(amountOut, 0, "Works with sufficient share");
    }

    /**
     * Test unconditional jump instruction
     */
    function test_Jump() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        // Build individual instructions
        bytes memory jumpInstr = program.build(_jump, ControlsArgsBuilder.buildJump(9)); // Will jump past deadline (3 bytes for jump instruction + 6 bytes for deadline)
        bytes memory deadlineInstr = program.build(_deadline, ControlsArgsBuilder.buildDeadline(uint40(block.timestamp - 1)));
        bytes memory balancesInstr = program.build(_staticBalancesXD,
            BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([uint256(100e18), uint256(100e18)])
            ));
        bytes memory swapInstr = program.build(_limitSwap1D,
            LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)));

        // Jump over the deadline instruction
        bytes memory bytecode = bytes.concat(
            jumpInstr,       // PC=0: Jump to PC=9 (skips deadline)
            deadlineInstr,   // PC=3: Should be skipped (expired deadline)
            balancesInstr,   // PC=9: Jump lands here
            swapInstr        // Execute swap
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Should execute successfully despite expired deadline being in the code
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertGt(amountOut, 0, "Jump skipped deadline check");
    }

    /**
     * Test jumpIfTokenOut instruction
     */
    function test_JumpIfTokenIn() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        // Build individual instructions to check sizes
        bytes memory jumpInstr = program.build(_jumpIfTokenIn,
            ControlsArgsBuilder.buildJumpIfToken(address(tokenB), 0)); // We'll calculate offset later
        bytes memory feeInstr = program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.1e9)); // 10%
        bytes memory balancesInstr = program.build(_staticBalancesXD,
            BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([uint256(100e18), uint256(100e18)])
            ));
        bytes memory swapInstr = program.build(_xycSwapXD);

        // Calculate the actual offset
        uint256 jumpSize = jumpInstr.length;
        uint256 feeSize = feeInstr.length;
        uint256 offset = uint16(jumpSize + feeSize);

        // Rebuild jump instruction with correct offset
        jumpInstr = program.build(_jumpIfTokenOut,
            ControlsArgsBuilder.buildJumpIfToken(address(tokenB), uint16(offset)));

        bytes memory bytecode = bytes.concat(
            jumpInstr,       // If output is tokenB, jump over fee
            feeInstr,        // Apply fee (will be skipped)
            balancesInstr,   // Set balances
            swapInstr        // Execute swap
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        uint256 snapshot = vm.snapshot();
        // Test A->B swap (output is tokenB, should skip fee)
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertEq(amountOut, 990099009900990099, "Should get ~1e18 without fee");
        vm.revertTo(snapshot);

        // Test B->A swap (output is tokenA, should apply fee)
        amountOut = _executeSwap(order, address(tokenB), address(tokenA), 1e18);
        assertEq(amountOut, 891089108910891090, "Should get ~0.9e18 with fee");
    }

    /**
     * Test jumpIfTokenOut instruction
     */
    function test_JumpIfTokenOut() public {
        Program memory program = ProgramBuilder.init(_opcodes());

        // Build individual instructions to check sizes
        bytes memory jumpInstr = program.build(_jumpIfTokenOut,
            ControlsArgsBuilder.buildJumpIfToken(address(tokenB), 0)); // We'll calculate offset later
        bytes memory feeInstr = program.build(_flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(0.1e9)); // 10%
        bytes memory balancesInstr = program.build(_staticBalancesXD,
            BalancesArgsBuilder.build(
                dynamic([address(tokenA), address(tokenB)]),
                dynamic([uint256(100e18), uint256(100e18)])
            ));
        bytes memory swapInstr = program.build(_xycSwapXD);

        // Calculate the actual offset
        uint256 jumpSize = jumpInstr.length;
        uint256 feeSize = feeInstr.length;
        uint256 offset = uint16(jumpSize + feeSize);

        // Rebuild jump instruction with correct offset
        jumpInstr = program.build(_jumpIfTokenOut,
            ControlsArgsBuilder.buildJumpIfToken(address(tokenB), uint16(offset)));

        bytes memory bytecode = bytes.concat(
            jumpInstr,       // If output is tokenB, jump over fee
            feeInstr,        // Apply fee (will be skipped)
            balancesInstr,   // Set balances
            swapInstr        // Execute swap
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        uint256 snapshot = vm.snapshot();
        // Test A->B swap (output is tokenB, should skip fee)
        uint256 amountOut = _executeSwap(order, address(tokenA), address(tokenB), 1e18);
        assertEq(amountOut, 990099009900990099, "Should get ~1e18 without fee");
        vm.revertTo(snapshot);

        // Test B->A swap (output is tokenA, should apply fee)
        amountOut = _executeSwap(order, address(tokenB), address(tokenA), 1e18);
        assertEq(amountOut, 891089108910891090, "Should get ~0.9e18 with fee");
    }

    // Helper functions
    function _buildSimpleSwapWithSalt(uint64 salt) private view returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            program.build(_salt, ControlsArgsBuilder.buildSalt(salt)),
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(100e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _executeSwap(
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) private returns (uint256) {
        bytes memory takerData = _signAndPackTakerData(order, true, 0);
        TokenMock(tokenIn).mint(taker, amount);

        (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        require(actualIn == amount, "Unexpected input amount");
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
}
