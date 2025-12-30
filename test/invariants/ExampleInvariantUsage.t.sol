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
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { FeeArgsBuilderExperimental } from "../../src/instructions/FeeExperimental.sol";
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title ExampleInvariantUsage
 * @notice Example demonstrating how to use CoreInvariants in your tests
 * @dev Shows various patterns for testing different instruction types
 */
contract ExampleInvariantUsage is Test, OpcodesDebug, CoreInvariants {
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
        tokenA.mint(maker, 1000e18);
        tokenB.mint(maker, 1000e18);
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
     * @dev This handles token minting and actual swap execution
     * @dev For assertAdditivityInvariant, this always uses exactIn mode where amount is the input amount
     */
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Note: assertAdditivityInvariant always passes input amounts for exactIn swaps
        // The takerData should already be configured for exactIn

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
     * Example 1: Test a simple limit order maintains all invariants
     */
    function test_LimitOrderInvariants() public {
        // Build limit order program
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(200e18)])  // 1:2 rate
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test all invariants with proper taker data
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
     * Example 2: Test an AMM with fees maintains invariants
     */
    function test_AMMWithFeesInvariants() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(1000e18)])
                )),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(0.003e9)), // 0.3% fee
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Test with custom amounts
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 0.1e18;
        testAmounts[1] = 1e18;
        testAmounts[2] = 10e18;
        testAmounts[3] = 100e18;

        // Create config with proper taker data
        InvariantConfig memory config = createInvariantConfig(testAmounts, 2);
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
     * Example 3: Test progressive fees with custom configuration
     */
    function test_ProgressiveFeeInvariants() public {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(1000e18)])
                )),
            program.build(_progressiveFeeInXD,
                FeeArgsBuilderExperimental.buildProgressiveFee(0.1e9)), // 10% progressive
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Progressive fees need higher tolerance due to rounding
        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(1e18), uint256(10e18), uint256(50e18)]),
            1e10  // Higher tolerance for progressive fees
        );

        // Add custom taker data - exactOut needs high threshold to allow trades
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // Skip additivity test - progressive fees violate additivity by design
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
     * Example 4: Test specific invariants individually
     */
    function test_SpecificInvariants() public view {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(100e18), uint256(200e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        bytes memory exactOutData = _signAndPackTakerData(order, false, type(uint256).max);

        // Test individual invariants
        assertSymmetryInvariant(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            10e18,    // amount
            2,        // tolerance
            exactInData,
            exactOutData
        );

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 10e18;
        amounts[2] = 50e18;

        assertMonotonicityInvariant(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            amounts,
            exactInData,
            0  // strict monotonicity
        );

        assertBalanceSufficiencyInvariant(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            exactInData
        );
    }

    /**
     * Example 5: Skip certain invariants for special cases
     */
    function test_SkipCertainInvariants() public {
        // Create a flat-rate order (no price impact)
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_staticBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(2000e18)])
                )),
            program.build(_limitSwap1D,
                LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // For limit orders, skip additivity and monotonicity checks
        InvariantConfig memory config = _getDefaultConfig();
        config.skipAdditivity = true;    // Limit orders don't have state
        config.skipMonotonicity = true;  // Fixed rate, no price impact
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

        // TakerTraitsLib expects threshold to be exactly 32 bytes or empty
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
