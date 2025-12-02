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
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title DecayXYCInvariants
 * @notice Tests invariants for Decay AMM combined with XYCSwap
 * @dev Tests decaying offsets affecting XYC (constant product) swap behavior
 */
contract DecayXYCInvariants is Test, OpcodesDebug, CoreInvariants {
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

        // Setup tokens and approvals for taker (test contract)
        tokenA.mint(address(this), 10000e18);
        tokenB.mint(address(this), 10000e18);
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
        // For the swap call, we need to pass the original amount from quote
        // which CoreInvariants stored in the first quote call
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
     * Test Decay + XYCSwap with different decay periods
     */
    function test_DecayXYCDifferentPeriods() public {
        uint16[] memory periods = new uint16[](4);
        periods[0] = 60;     // 1 minute decay
        periods[1] = 300;    // 5 minutes decay
        periods[2] = 3600;   // 1 hour decay
        periods[3] = 43200;  // 12 hours decay (max that fits in uint16)

        for (uint256 i = 0; i < periods.length; i++) {
            _testDecayXYCWithPeriod(periods[i]);
        }
    }

    /**
     * Test Decay + XYCSwap with small decay period
     */
    function test_DecayXYCSmallPeriod() public {
        _testDecayXYCWithPeriod(30); // 30 seconds
    }

    /**
     * Test Decay + XYCSwap with medium decay period
     */
    function test_DecayXYCMediumPeriod() public {
        _testDecayXYCWithPeriod(600); // 10 minutes
    }

    /**
     * Test Decay + XYCSwap with large decay period
     */
    function test_DecayXYCLargePeriod() public {
        _testDecayXYCWithPeriod(7200); // 2 hours
    }

    /**
     * Test Decay + XYCSwap with exact halfway decay
     */
    function test_DecayXYCHalfwayDecay() public {
        uint16 period = 120; // 2 minutes

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(1000e18)])
                )),
            program.build(_decayXD,
                DecayArgsBuilder.build(period)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Execute initial trade
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 50e18, exactInData);

        // Wait for exactly half decay
        vm.warp(block.timestamp + period / 2);

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
     * Helper to test Decay + XYC with specific period
     */
    function _testDecayXYCWithPeriod(uint16 period) private {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([uint256(1000e18), uint256(1000e18)])
                )),
            program.build(_decayXD,
                DecayArgsBuilder.build(period)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        // Execute initial trade
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);
        _executeSwap(swapVM, order, address(tokenA), address(tokenB), 50e18, exactInData);

        // Wait for half decay
        vm.warp(block.timestamp + period / 2);

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
