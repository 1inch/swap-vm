// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { DecayArgsBuilder } from "../../src/instructions/Decay.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title ConcentrateXYCDecayInvariants
 * @notice Tests invariants for Concentrate + XYCSwap + Decay combination
 * @dev Tests concentrated liquidity with decaying offsets affecting swap behavior
 */
contract ConcentrateXYCDecayInvariants is Test, OpcodesDebug, CoreInvariants {
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
        swapVM = new SwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

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

    function _concentrateBalances(
        uint256 available,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal view returns (uint256 balA, uint256 balB) {
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
                available, available, 1e18, sqrtPmin, sqrtPmax
            );
        (balA, balB) = address(tokenA) < address(tokenB)
            ? (actualLt, actualGt)
            : (actualGt, actualLt);
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
     * Test _xycConcentrateGrowLiquidity2D + Decay invariants
     */
    function test_ConcentrateGrowLiquidity2D_Decay() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1000e18, sqrtPmin, sqrtPmax);
        uint16 decayPeriod = 300; // 5 minutes
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
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
     * Test different decay periods
     */
    function test_ConcentrateVariousDecayPeriods() public {
        uint16[] memory decayPeriods = new uint16[](4);
        decayPeriods[0] = 60;     // 1 minute
        decayPeriods[1] = 300;    // 5 minutes
        decayPeriods[2] = 1800;   // 30 minutes
        decayPeriods[3] = 7200;   // 2 hours

        for (uint256 i = 0; i < decayPeriods.length; i++) {
            _testDecayPeriod(decayPeriods[i]);
        }
    }

    /**
     * Helper to test specific decay period
     */
    function _testDecayPeriod(uint16 decayPeriod) private {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1500e18, sqrtPmin, sqrtPmax);
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_decayXD,
                DecayArgsBuilder.build(decayPeriod)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(2e18), uint256(5e18), uint256(10e18)]),
            1
        );
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
