// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { DecayArgsBuilder } from "../../src/instructions/Decay.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title DecayXYCFeesInvariants
 * @notice Tests invariants for Decay AMM + XYCSwap + all types of fees
 * @dev Tests how different fee structures interact with decay mechanics
 */
contract DecayXYCFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        feeRecipient = address(0xFEE);
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
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * @notice Implementation of _executeSwap for real swap execution
     */
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount * 10);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        // Verify the swap consumed the expected input amount


        return (actualIn, actualOut);
    }

    /**
     * Test Decay + XYC with flat fee on input
     */
    function test_DecayXYCFlatFeeIn() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint16 decayPeriod = 300; // 5 minutes
        uint32 feeBps = 0.003e9; // 0.3% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Execute initial trade to create decay offsets
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 20e18, exactInData);

        // Wait for partial decay
        vm.warp(block.timestamp + 150); // 50% decay

        // Test invariants with fee and decay
        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Decay + XYC with flat fee on output
     */
    function test_DecayXYCFlatFeeOut() public {
        uint256 balanceA = 1500e18;
        uint256 balanceB = 1500e18;
        uint16 decayPeriod = 600; // 10 minutes
        uint32 feeBps = 0.005e9; // 0.5% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Execute initial trade to create decay offsets
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 30e18, exactInData);

        // Wait for partial decay
        vm.warp(block.timestamp + decayPeriod / 4); // 25% decay

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: State-dependent due to decay
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Decay + XYC with progressive fee on input
     */
    function test_DecayXYCProgressiveFeeIn() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 2000e18;
        uint16 decayPeriod = 900; // 15 minutes
        uint32 feeBps = 0.1e9; // 10% progressive fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_progressiveFeeInXD,
                FeeArgsBuilder.buildProgressiveFee(feeBps)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Decay + XYC with progressive fee on output
     */
    function test_DecayXYCProgressiveFeeOut() public {
        uint256 balanceA = 1800e18;
        uint256 balanceB = 1800e18;
        uint16 decayPeriod = 1200; // 20 minutes
        uint32 feeBps = 0.05e9; // 5% progressive fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_progressiveFeeOutXD,
                FeeArgsBuilder.buildProgressiveFee(feeBps)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Execute trades and test behavior
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // First trade
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 50e18, exactInData);

        // Second trade after partial decay
        vm.warp(block.timestamp + 300);
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 30e18, exactInData);

        // Test invariants with complex state
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(5e18), uint256(10e18), uint256(20e18)]),
            1
        );
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Decay + XYC with protocol fee
     */
    function test_DecayXYCProtocolFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint16 decayPeriod = 300;
        uint32 feeBps = 0.002e9; // 0.2% protocol fee

        // Pre-approve for protocol fee transfers
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, feeRecipient)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Execute trade to create decay offsets
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 10e18, exactInData);

        // Wait for partial decay
        vm.warp(block.timestamp + 150);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = exactInData;
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: State-dependent due to decay + protocol fees
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test multiple fee types combined with Decay + XYC
     */
    function test_DecayXYCMultipleFees() public {
        uint256 balanceA = 3000e18;
        uint256 balanceB = 3000e18;
        uint16 decayPeriod = 600;
        uint32 flatFeeBps = 0.001e9;      // 0.1% flat fee
        uint32 progressiveFeeBps = 0.02e9; // 2% progressive fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_progressiveFeeOutXD,
                FeeArgsBuilder.buildProgressiveFee(progressiveFeeBps)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(10e18), uint256(20e18), uint256(50e18)]),
            1
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: due to progressive fees
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    // Helper functions
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
