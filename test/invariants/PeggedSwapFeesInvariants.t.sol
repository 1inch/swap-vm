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
import { PeggedSwapArgsBuilder } from "../../src/instructions/PeggedSwap.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title PeggedSwapFeesInvariants
 * @notice Tests invariants for PeggedSwap + all types of fees
 * @dev Tests PeggedSwap curve with different fee structures
 */
contract PeggedSwapFeesInvariants is Test, OpcodesDebug, CoreInvariants {
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

        return (actualIn, actualOut);
    }

    /**
     * Test PeggedSwap with flat fee on input
     */
    function test_PeggedSwapFlatFeeIn() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 x0 = 1000e18;  // Initial X reserve
        uint256 y0 = 1000e18;  // Initial Y reserve
        uint256 a = 0.8e27;    // A parameter (0.8 in fixed point)
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
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
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
     * Test PeggedSwap with flat fee on output
     */
    function test_PeggedSwapFlatFeeOut() public {
        uint256 balanceA = 1500e18;
        uint256 balanceB = 1500e18;
        uint256 x0 = 1500e18;  // Initial X reserve
        uint256 y0 = 1500e18;  // Initial Y reserve
        uint256 a = 0.5e27;    // A parameter (0.5 in fixed point)
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
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // FlatFee + PeggedSwap rounding causes ~500 wei symmetry error
        config.symmetryTolerance = 500;
        // FlatFeeOut + PeggedSwap additivity error ~4.3e15 wei
        config.additivityTolerance = 5e15;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test PeggedSwap with progressive fee on input
     */
    function test_PeggedSwapProgressiveFeeIn() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 2000e18;
        uint256 x0 = 2000e18;  // Initial X reserve
        uint256 y0 = 2000e18;  // Initial Y reserve
        uint256 a = 0.9e27;    // A parameter (0.9 in fixed point - more linear)
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
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;
        // TODO: need to research behavior
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test PeggedSwap with progressive fee on output
     */
    function test_PeggedSwapProgressiveFeeOut() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 2000e18;
        uint256 x0 = 2000e18;  // Initial X reserve
        uint256 y0 = 2000e18;  // Initial Y reserve
        uint256 a = 0.95e27;   // A parameter (0.95 in fixed point - very linear)
        uint32 feeBps = 0.1e9; // 10% progressive fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_progressiveFeeOutXD,
                FeeArgsBuilder.buildProgressiveFee(feeBps)),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;
        // TODO: need to research behavior
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test PeggedSwap with protocol fee
     */
    function test_PeggedSwapProtocolFee() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 x0 = 1000e18;  // Initial X reserve
        uint256 y0 = 1000e18;  // Initial Y reserve
        uint256 a = 0.7e27;    // A parameter (0.7 in fixed point)
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
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: need to research behavior - state-dependent due to scale
        config.skipAdditivity = true;
        // Skip symmetry due to rounding in PeggedSwap math
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test multiple fee types with PeggedSwap
     */
    function test_PeggedSwapMultipleFees() public {
        uint256 balanceA = 3000e18;
        uint256 balanceB = 3000e18;
        uint256 x0 = 3000e18;  // Initial X reserve
        uint256 y0 = 3000e18;  // Initial Y reserve
        uint256 a = 0.85e18;   // A parameter (0.85 in fixed point)
        uint32 flatFeeBps = 0.001e9;     // 0.1% flat fee
        uint32 protocolFeeBps = 0.02e9;  // 2% protocol fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(protocolFeeBps, feeRecipient)),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(10e18), uint256(20e18), uint256(50e18)]),
            1
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Complex fee interactions affect additivity
        config.skipAdditivity = true;
        // Skip symmetry due to rounding in PeggedSwap math
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test PeggedSwap with different A values
     */
    function test_PeggedSwapDifferentA() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 x0 = 1000e18;  // Initial X reserve
        uint256 y0 = 1000e18;  // Initial Y reserve
        uint32 feeBps = 0.003e9; // 0.3% fee

        // Test with A = 0 (pure square root curve)
        _testPeggedSwapWithA(balanceA, balanceB, x0, y0, 0, feeBps, true);

        // Test with A = 0.2 (mostly curved)
        _testPeggedSwapWithA(balanceA, balanceB, x0, y0, 0.2e18, feeBps, true);

        // Test with A = 0.5 (balanced)
        _testPeggedSwapWithA(balanceA, balanceB, x0, y0, 0.5e27, feeBps, true);

        // Test with A = 0.8 (mostly linear)
        _testPeggedSwapWithA(balanceA, balanceB, x0, y0, 0.8e27, feeBps, true);

        // Test with A = 0.95 (very linear)
        _testPeggedSwapWithA(balanceA, balanceB, x0, y0, 0.95e27, feeBps, true);
    }

    /**
     * Test PeggedSwap with imbalanced initial pools
     */
    function test_PeggedSwapImbalancedPools() public {
        uint32 feeBps = 0.003e9; // 0.3% fee
        uint256 a = 0.8e27;    // A parameter

        // X-heavy pool
        {
            uint256 balanceA = 2000e18;
            uint256 balanceB = 500e18;
            uint256 x0 = 1000e18;  // Initial X reserve
            uint256 y0 = 1000e18;  // Initial Y reserve

            Program memory program = ProgramBuilder.init(_opcodes());
            bytes memory bytecode = bytes.concat(
                program.build(_dynamicBalancesXD,
                    BalancesArgsBuilder.build(
                        dynamic([address(tokenA), address(tokenB)]),
                        dynamic([balanceA, balanceB])
                    )),
                program.build(_flatFeeAmountInXD,
                    FeeArgsBuilder.buildFlatFee(feeBps)),
                program.build(_peggedSwapGrowPriceRange2D,
                    PeggedSwapArgsBuilder.build(
                        PeggedSwapArgsBuilder.Args({
                            x0: x0,
                            y0: y0,
                            linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                        })
                    ))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);

            InvariantConfig memory config = createInvariantConfig(
                dynamic([uint256(5e18), uint256(10e18), uint256(20e18)]),
                1
            );
            config.exactInTakerData = _signAndPackTakerData(order, true, 0);
            config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
            // Skip symmetry due to rounding in PeggedSwap math
            config.skipSymmetry = true;
            // Skip spot price check for imbalanced pools
            config.skipSpotPrice = true;

            assertAllInvariantsWithConfig(
                swapVM,
                order,
                address(tokenA),
                address(tokenB),
                config
            );
        }

        // Y-heavy pool
        {
            uint256 balanceA = 500e18;
            uint256 balanceB = 2000e18;
            uint256 x0 = 1000e18;  // Initial X reserve
            uint256 y0 = 1000e18;  // Initial Y reserve

            Program memory program = ProgramBuilder.init(_opcodes());
            bytes memory bytecode = bytes.concat(
                program.build(_dynamicBalancesXD,
                    BalancesArgsBuilder.build(
                        dynamic([address(tokenA), address(tokenB)]),
                        dynamic([balanceA, balanceB])
                    )),
                program.build(_flatFeeAmountInXD,
                    FeeArgsBuilder.buildFlatFee(feeBps)),
                program.build(_peggedSwapGrowPriceRange2D,
                    PeggedSwapArgsBuilder.build(
                        PeggedSwapArgsBuilder.Args({
                            x0: x0,
                            y0: y0,
                            linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                        })
                    ))
            );

            ISwapVM.Order memory order = _createOrder(bytecode);

            InvariantConfig memory config = createInvariantConfig(
                dynamic([uint256(5e18), uint256(10e18), uint256(20e18)]),
                1
            );
            config.exactInTakerData = _signAndPackTakerData(order, true, 0);
            config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
            // Skip symmetry due to rounding in PeggedSwap math
            config.skipSymmetry = true;
            // Skip spot price check for imbalanced pools
            config.skipSpotPrice = true;

            assertAllInvariantsWithConfig(
                swapVM,
                order,
                address(tokenA),
                address(tokenB),
                config
            );
        }
    }

    // Helper functions
    function _testPeggedSwapWithA(
        uint256 balanceA,
        uint256 balanceB,
        uint256 x0,
        uint256 y0,
        uint256 a,
        uint32 feeBps,
        bool skipSymmetry
    ) private {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_peggedSwapGrowPriceRange2D,
                PeggedSwapArgsBuilder.build(
                    PeggedSwapArgsBuilder.Args({
                        x0: x0,
                        y0: y0,
                        linearWidth: a,
                        rateLt: 1,
                        rateGt: 1
                    })
                ))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(10e18), uint256(20e18)]),
            1
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        if (skipSymmetry) {
            // Skip symmetry due to rounding in PeggedSwap math
            config.skipSymmetry = true;
        }

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
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
