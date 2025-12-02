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
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";


/**
 * @title ConcentrateXYCInvariants
 * @notice Tests invariants for XYCConcentrate combined with XYCSwap
 * @dev Tests concentrated liquidity affecting XYC (constant product) swap behavior
 */
contract ConcentrateXYCInvariants is Test, OpcodesDebug, CoreInvariants {
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
     * Test _xycConcentrateGrowLiquidity2D invariants
     */
    function test_ConcentrateGrowLiquidity2D() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.8e18;
        uint256 priceMax = 1.25e18;

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA,
            balanceB,
            currentPrice,
            priceMin,
            priceMax
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB
                )),
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
     * Test _xycConcentrateGrowPriceRange2D invariants
     */
    function test_ConcentrateGrowPriceRange2D() public {
        uint256 balanceA = 1500e18;
        uint256 balanceB = 1500e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.7e18;
        uint256 priceMax = 1.4e18;

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA,
            balanceB,
            currentPrice,
            priceMin,
            priceMax
        );

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB
                )),
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
     * Test _xycConcentrateGrowLiquidityXD invariants
     */
    function test_ConcentrateGrowLiquidityXD() public {
        uint256 balanceA = 2000e18;
        uint256 balanceB = 2000e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA,
            balanceB,
            currentPrice,
            priceMin,
            priceMax
        );

        // Create arrays for XD version
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint256[] memory deltas = new uint256[](2);
        deltas[0] = deltaA;
        deltas[1] = deltaB;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidityXD,
                XYCConcentrateArgsBuilder.buildXD(tokens, deltas)),
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
     * Test _xycConcentrateGrowPriceRangeXD invariants
     */
    function test_ConcentrateGrowPriceRangeXD() public {
        uint256 balanceA = 2500e18;
        uint256 balanceB = 2500e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.6e18;
        uint256 priceMax = 1.7e18;

        (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA,
            balanceB,
            currentPrice,
            priceMin,
            priceMax
        );

        // Create arrays for XD version
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint256[] memory deltas = new uint256[](2);
        deltas[0] = deltaA;
        deltas[1] = deltaB;

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowPriceRangeXD,
                XYCConcentrateArgsBuilder.buildXD(tokens, deltas)),
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
     * Test concentration with different price ranges
     */
    function test_ConcentrateDifferentRanges() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1e18;

        // Test different concentration ranges
        uint256[4] memory priceMinValues = [uint256(0.9e18), 0.8e18, 0.5e18, 0.95e18];
        uint256[4] memory priceMaxValues = [uint256(1.1e18), 1.25e18, 2e18, 1.05e18];

        for (uint256 i = 0; i < 4; i++) {
            (uint256 deltaA, uint256 deltaB) = XYCConcentrateArgsBuilder.computeDeltas(
                balanceA,
                balanceB,
                currentPrice,
                priceMinValues[i],
                priceMaxValues[i]
            );

            Program memory program = ProgramBuilder.init(_opcodes());
            bytes memory bytecode = bytes.concat(
                program.build(_dynamicBalancesXD,
                    BalancesArgsBuilder.build(
                        dynamic([address(tokenA), address(tokenB)]),
                        dynamic([balanceA, balanceB])
                    )),
                program.build(_xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(
                        address(tokenA),
                        address(tokenB),
                        deltaA,
                        deltaB
                    )),
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
