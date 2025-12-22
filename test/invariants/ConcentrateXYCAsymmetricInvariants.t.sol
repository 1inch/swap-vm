// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
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
 * @title ConcentrateXYCAsymmetricInvariants
 * @notice Tests invariants for XYCConcentrate with asymmetric price ranges
 * @dev Tests both GrowPriceRange2D and GrowLiquidity2D with extreme and asymmetric price bounds
 */
contract ConcentrateXYCAsymmetricInvariants is Test, OpcodesDebug, CoreInvariants {
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

        return (actualIn, actualOut);
    }

    // ============================================================
    // GrowPriceRange2D Tests - Asymmetric Price Ranges
    // ============================================================

    /**
     * Test GrowPriceRange2D with price range shifted heavily LEFT (low prices)
     * Price: 0.3e18, Range: [0.1e18, 0.5e18]
     */
    function test_GrowPriceRange2D_LeftShiftedRange() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 300e18;  // Lower B balance for low price
        uint256 currentPrice = 0.3e18;
        uint256 priceMin = 0.1e18;
        uint256 priceMax = 0.5e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with price range shifted heavily RIGHT (high prices)
     * Price: 5e18, Range: [2e18, 10e18]
     */
    function test_GrowPriceRange2D_RightShiftedRange() public {
        uint256 balanceA = 200e18;  // Lower A balance for high price
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 5e18;
        uint256 priceMin = 2e18;
        uint256 priceMax = 10e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with current price at lower bound
     * Price: 0.5e18, Range: [0.5e18, 2e18]
     */
    function test_GrowPriceRange2D_PriceAtLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 500e18;
        uint256 currentPrice = 0.5e18;
        uint256 priceMin = 0.5e18;  // Price at lower bound
        uint256 priceMax = 2e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with current price at upper bound
     * Price: 3e18, Range: [0.5e18, 3e18]
     */
    function test_GrowPriceRange2D_PriceAtUpperBound() public {
        uint256 balanceA = 333e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 3e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 3e18;  // Price at upper bound

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with very narrow asymmetric range
     * Price: 1.5e18, Range: [1.4e18, 1.55e18] (narrow, not centered)
     */
    function test_GrowPriceRange2D_NarrowAsymmetric() public {
        uint256 balanceA = 666e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1.5e18;
        uint256 priceMin = 1.4e18;
        uint256 priceMax = 1.55e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with very wide asymmetric range
     * Price: 1e18, Range: [0.01e18, 100e18]
     */
    function test_GrowPriceRange2D_VeryWideAsymmetric() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.01e18;
        uint256 priceMax = 100e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with extreme price ratio (100x)
     * Price: 10e18, Range: [1e18, 100e18]
     */
    function test_GrowPriceRange2D_ExtremePriceRatio() public {
        uint256 balanceA = 100e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 10e18;
        uint256 priceMin = 1e18;
        uint256 priceMax = 100e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with price close to lower bound but not at it
     * Price: 0.51e18, Range: [0.5e18, 2e18]
     */
    function test_GrowPriceRange2D_PriceNearLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 510e18;
        uint256 currentPrice = 0.51e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowPriceRange2D with price close to upper bound but not at it
     * Price: 1.99e18, Range: [0.5e18, 2e18]
     */
    function test_GrowPriceRange2D_PriceNearUpperBound() public {
        uint256 balanceA = 500e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1.99e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        _testGrowPriceRange2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    // ============================================================
    // GrowLiquidity2D Tests - Asymmetric Price Ranges
    // ============================================================

    /**
     * Test GrowLiquidity2D with price range shifted heavily LEFT (low prices)
     * Price: 0.3e18, Range: [0.1e18, 0.5e18]
     */
    function test_GrowLiquidity2D_LeftShiftedRange() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 300e18;
        uint256 currentPrice = 0.3e18;
        uint256 priceMin = 0.1e18;
        uint256 priceMax = 0.5e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with price range shifted heavily RIGHT (high prices)
     * Price: 5e18, Range: [2e18, 10e18]
     */
    function test_GrowLiquidity2D_RightShiftedRange() public {
        uint256 balanceA = 200e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 5e18;
        uint256 priceMin = 2e18;
        uint256 priceMax = 10e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with current price at lower bound
     * Price: 0.5e18, Range: [0.5e18, 2e18]
     */
    function test_GrowLiquidity2D_PriceAtLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 500e18;
        uint256 currentPrice = 0.5e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with current price at upper bound
     * Price: 3e18, Range: [0.5e18, 3e18]
     */
    function test_GrowLiquidity2D_PriceAtUpperBound() public {
        uint256 balanceA = 333e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 3e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 3e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with very narrow asymmetric range
     * Price: 1.5e18, Range: [1.4e18, 1.55e18]
     */
    function test_GrowLiquidity2D_NarrowAsymmetric() public {
        uint256 balanceA = 666e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1.5e18;
        uint256 priceMin = 1.4e18;
        uint256 priceMax = 1.55e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with very wide asymmetric range
     * Price: 1e18, Range: [0.01e18, 100e18]
     */
    function test_GrowLiquidity2D_VeryWideAsymmetric() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1e18;
        uint256 priceMin = 0.01e18;
        uint256 priceMax = 100e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with extreme price ratio (100x)
     * Price: 10e18, Range: [1e18, 100e18]
     */
    function test_GrowLiquidity2D_ExtremePriceRatio() public {
        uint256 balanceA = 100e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 10e18;
        uint256 priceMin = 1e18;
        uint256 priceMax = 100e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with price close to lower bound
     * Price: 0.51e18, Range: [0.5e18, 2e18]
     */
    function test_GrowLiquidity2D_PriceNearLowerBound() public {
        uint256 balanceA = 1000e18;
        uint256 balanceB = 510e18;
        uint256 currentPrice = 0.51e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    /**
     * Test GrowLiquidity2D with price close to upper bound
     * Price: 1.99e18, Range: [0.5e18, 2e18]
     */
    function test_GrowLiquidity2D_PriceNearUpperBound() public {
        uint256 balanceA = 500e18;
        uint256 balanceB = 1000e18;
        uint256 currentPrice = 1.99e18;
        uint256 priceMin = 0.5e18;
        uint256 priceMax = 2e18;

        _testGrowLiquidity2D(balanceA, balanceB, currentPrice, priceMin, priceMax);
    }

    // ============================================================
    // Helper Functions
    // ============================================================

    function _testGrowPriceRange2D(
        uint256 balanceA,
        uint256 balanceB,
        uint256 currentPrice,
        uint256 priceMin,
        uint256 priceMax
    ) internal {
        (uint256 deltaA, uint256 deltaB, uint256 liq) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA,
            balanceB,
            currentPrice,
            priceMin,
            priceMax
        );

        console.log("=== GrowPriceRange2D Test ===");
        console.log("balanceA:", balanceA);
        console.log("balanceB:", balanceB);
        console.log("currentPrice:", currentPrice);
        console.log("priceMin:", priceMin);
        console.log("priceMax:", priceMax);
        console.log("deltaA:", deltaA);
        console.log("deltaB:", deltaB);
        console.log("liquidity:", liq);

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
                    deltaB,
                    liq
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

    function _testGrowLiquidity2D(
        uint256 balanceA,
        uint256 balanceB,
        uint256 currentPrice,
        uint256 priceMin,
        uint256 priceMax
    ) internal {
        (uint256 deltaA, uint256 deltaB, uint256 liq) = XYCConcentrateArgsBuilder.computeDeltas(
            balanceA,
            balanceB,
            currentPrice,
            priceMin,
            priceMax
        );

        console.log("=== GrowLiquidity2D Test ===");
        console.log("balanceA:", balanceA);
        console.log("balanceB:", balanceB);
        console.log("currentPrice:", currentPrice);
        console.log("priceMin:", priceMin);
        console.log("priceMax:", priceMax);
        console.log("deltaA:", deltaA);
        console.log("deltaB:", deltaB);
        console.log("liquidity:", liq);

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
                    deltaB,
                    liq
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

