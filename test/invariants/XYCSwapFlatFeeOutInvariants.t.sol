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
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title XYCSwapFlatFeeOutInvariants
 * @notice Tests invariants for XYCSwap combined with flat fee on output
 * @dev Tests XYC swap behavior with flat fee applied to output amount
 *      Note: Fee instructions must be placed BEFORE the swap instruction
 */
contract XYCSwapFlatFeeOutInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    // Skip additivity check - FeeOut breaks additivity now
    bool internal constant SKIP_ADDITIVITY = true;

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
        tokenA.mint(maker, 10000000e18);
        tokenB.mint(maker, 10000000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup tokens and approvals for taker (test contract)
        tokenA.mint(address(this), 10000000e18);
        tokenB.mint(address(this), 10000000e18);
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
     * Test XYC + FlatFeeOut with equal balances (1:1 ratio)
     */
    function test_XYCFlatFeeOutBasic() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint32 feeBps = 0.003e9; // 0.3% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.skipAdditivity = SKIP_ADDITIVITY;
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
     * Test XYC + FlatFeeOut with different balance ratios
     */
    function test_XYCFlatFeeOutDifferentBalances() public {
        uint32 feeBps = 0.003e9; // 0.3% fee
        
        // Test multiple balance ratios
        uint256[4] memory balancesA = [uint256(2000e18), 1000e18, 500e18, 3000e18];
        uint256[4] memory balancesB = [uint256(1000e18), 2000e18, 1500e18, 1000e18];

        for (uint256 i = 0; i < 4; i++) {
            _testXYCFlatFeeOutWithBalances(balancesA[i], balancesB[i], feeBps);
        }
    }

    /**
     * Test XYC + FlatFeeOut with different fee percentages
     */
    function test_XYCFlatFeeOutDifferentFees() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        
        // Test different fee percentages
        uint32[4] memory fees = [uint32(0.001e9), uint32(0.003e9), uint32(0.005e9), uint32(0.01e9)]; // 0.1%, 0.3%, 0.5%, 1%

        for (uint256 i = 0; i < 4; i++) {
            _testXYCFlatFeeOutWithBalances(balanceA, balanceB, fees[i]);
        }
    }

    /**
     * Test XYC + FlatFeeOut with large liquidity pool
     */
    function test_XYCFlatFeeOutLargeLiquidity() public {
        uint256 balanceA = 1000000e18; // 1 million tokens
        uint256 balanceB = 1000000e18;
        uint32 feeBps = 0.003e9; // 0.3% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Use larger test amounts for large pool
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 10000e18;
        testAmounts[1] = 50000e18;
        testAmounts[2] = 100000e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 2);
        config.skipAdditivity = SKIP_ADDITIVITY;
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
     * Test XYC + FlatFeeOut with small liquidity pool
     */
    function test_XYCFlatFeeOutSmallLiquidity() public {
        uint256 balanceA = 100e18; // 100 tokens
        uint256 balanceB = 100e18;
        uint32 feeBps = 0.003e9; // 0.3% fee

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Use smaller test amounts for small pool
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1e18;
        testAmounts[1] = 5e18;
        testAmounts[2] = 10e18;

        InvariantConfig memory config = createInvariantConfig(testAmounts, 2);
        config.skipAdditivity = SKIP_ADDITIVITY;
        config.skipSpotPrice = true; // Skip spot price for small pool - rounding is significant
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
     * Helper to test XYC + FlatFeeOut with specific balances and fee
     */
    function _testXYCFlatFeeOutWithBalances(uint256 balanceA, uint256 balanceB, uint32 feeBps) private {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Higher tolerance for fee scenarios due to combined rounding from fee + XYC
        InvariantConfig memory config = _getDefaultConfig();
        config.skipAdditivity = SKIP_ADDITIVITY;
        config.symmetryTolerance = 10; // Increased tolerance for fee rounding
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
