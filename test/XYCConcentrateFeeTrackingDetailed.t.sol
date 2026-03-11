// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/// @title Detailed fee accumulation tracking in XYCConcentrate
/// @notice This test creates snapshot orders without fees in each iteration
///         to precisely determine in which token fees accumulate

import { Test } from "forge-std/Test.sol";
import { dynamic } from "./utils/Dynamic.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract XYCConcentrateFeeTrackingDetailedTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenUSD;
    address public tokenETH;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint32 public constant FLAT_FEE_BPS = 0.003e9; // 0.3%
    uint256 public constant BPS = 1e9;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        swapVM = new SwapVMRouter(address(0), address(0), "SwapVM", "1.0.0");

        address _tA = address(new TokenMock("USD Token", "USD"));
        address _tB = address(new TokenMock("ETH Token", "ETH"));
        (tokenUSD, tokenETH) = _tA > _tB ? (_tA, _tB) : (_tB, _tA);

        TokenMock(tokenUSD).mint(maker, 100_000_000e18);
        TokenMock(tokenETH).mint(maker, 100_000_000e18);
        TokenMock(tokenUSD).mint(taker, 100_000_000e18);
        TokenMock(tokenETH).mint(taker, 100_000_000e18);

        vm.prank(maker);
        TokenMock(tokenUSD).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenETH).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenUSD).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenETH).approve(address(swapVM), type(uint256).max);
    }

    /// @notice Create order with given balances
    function _createOrderWithBalances(
        uint256 balanceUSD,
        uint256 balanceETH,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 flatFeeBps
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory feeInstruction = flatFeeBps > 0
            ? program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeBps))
            : bytes("");

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: bytes.concat(
                program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenUSD), address(tokenETH)]),
                    dynamic([balanceUSD, balanceETH])
                )),
                program.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(sqrtPriceMin, sqrtPriceMax)
                ),
                feeInstruction,
                program.build(XYCSwap._xycSwapXD)
            )
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _takerData(bool isExactIn, bytes memory sig) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: sig
        }));
    }

    function test_DetailedFeeTracking_PerIteration() public {
        // Initial parameters: USD/ETH pool, bounds [2000-4000], spot ~3000
        uint256 sqrtPriceMin = Math.sqrt(2000e18 * 1e18);
        uint256 sqrtPriceMax = Math.sqrt(4000e18 * 1e18);

        // Initial liquidity
        uint256 initialUSD = 3_000_000e18;
        uint256 initialETH = 1000e18;
        uint256 spotPrice = 3000e18;
        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            initialETH, initialUSD, Math.sqrt(spotPrice * 1e18), sqrtPriceMin, sqrtPriceMax
        );
        uint256 actualBalanceUSD = address(tokenUSD) > address(tokenETH) ? bGt : bLt;
        uint256 actualBalanceETH = address(tokenUSD) > address(tokenETH) ? bLt : bGt;

        // Create main order WITH fees
        (ISwapVM.Order memory mainOrder, bytes memory mainSig) = _createOrderWithBalances(
            actualBalanceUSD,
            actualBalanceETH,
            sqrtPriceMin,
            sqrtPriceMax,
            FLAT_FEE_BPS
        );
        bytes32 mainHash = swapVM.hash(mainOrder);

        // Initialization
        vm.prank(taker);
        swapVM.swap(mainOrder, tokenETH, tokenUSD, 1e18, _takerData(false, mainSig));

        uint256 swapAmountUSD = 1000e18;
        uint256 roundsToTest = 1000;
        uint256 totalFeeUSD = 0;
        uint256 totalFeeETH = 0;

        for (uint256 i = 0; i < roundsToTest; i++) {
            uint256 currentUSD = swapVM.balances(mainHash, tokenUSD);
            uint256 currentETH = swapVM.balances(mainHash, tokenETH);

            // First swap: exactOut (ETH->USD)
            (ISwapVM.Order memory snapshot1, bytes memory snap1Sig) = _createOrderWithBalances(
                currentUSD, currentETH, sqrtPriceMin, sqrtPriceMax, 0
            );
            bytes32 snap1Hash = swapVM.hash(snapshot1);

            vm.prank(taker);
            swapVM.swap(mainOrder, tokenETH, tokenUSD, swapAmountUSD, _takerData(false, mainSig));
            vm.prank(taker);
            swapVM.swap(snapshot1, tokenETH, tokenUSD, swapAmountUSD, _takerData(false, snap1Sig));

            uint256 mainUSD_after1 = swapVM.balances(mainHash, tokenUSD);
            uint256 mainETH_after1 = swapVM.balances(mainHash, tokenETH);
            uint256 snapUSD_after1 = swapVM.balances(snap1Hash, tokenUSD);
            uint256 snapETH_after1 = swapVM.balances(snap1Hash, tokenETH);

            int256 feeUSD_swap1 = int256(mainUSD_after1) - int256(snapUSD_after1);
            int256 feeETH_swap1 = int256(mainETH_after1) - int256(snapETH_after1);

            // Second swap: exactIn (USD->ETH)
            (ISwapVM.Order memory snapshot2, bytes memory snap2Sig) = _createOrderWithBalances(
                mainUSD_after1, mainETH_after1, sqrtPriceMin, sqrtPriceMax, 0
            );
            bytes32 snap2Hash = swapVM.hash(snapshot2);

            vm.prank(taker);
            (, uint256 ethReceived_main,) = swapVM.swap(
                mainOrder, tokenUSD, tokenETH, swapAmountUSD, _takerData(true, mainSig)
            );

            uint256 flatFeeAmount = swapAmountUSD * FLAT_FEE_BPS / BPS;
            uint256 amountInAfterFee = swapAmountUSD - flatFeeAmount;

            vm.prank(taker);
            (, uint256 ethReceived_snap,) = swapVM.swap(
                snapshot2, tokenUSD, tokenETH, amountInAfterFee, _takerData(true, snap2Sig)
            );

            assertApproxEqAbs(ethReceived_main, ethReceived_snap, 1e10, "AmountOut mismatch");

            uint256 mainUSD_after2 = swapVM.balances(mainHash, tokenUSD);
            uint256 mainETH_after2 = swapVM.balances(mainHash, tokenETH);
            uint256 snapUSD_after2 = swapVM.balances(snap2Hash, tokenUSD);
            uint256 snapETH_after2 = swapVM.balances(snap2Hash, tokenETH);

            int256 feeUSD_swap2 = int256(mainUSD_after2) - int256(snapUSD_after2);
            int256 feeETH_swap2 = int256(mainETH_after2) - int256(snapETH_after2);

            int256 roundFeeUSD = feeUSD_swap1 + feeUSD_swap2;
            int256 roundFeeETH = feeETH_swap1 + feeETH_swap2;

            totalFeeUSD += roundFeeUSD > 0 ? uint256(roundFeeUSD) : 0;
            totalFeeETH += roundFeeETH > 0 ? uint256(roundFeeETH) : 0;
        }

        // Final analysis
        uint256 finalUSD = swapVM.balances(mainHash, tokenUSD);
        uint256 finalETH = swapVM.balances(mainHash, tokenETH);

        (, uint256 finalSqrtP) = XYCConcentrateArgsBuilder.computeLiquidityAndPrice(
            finalETH, finalUSD, sqrtPriceMin, sqrtPriceMax
        );
        uint256 finalSpotPrice = (finalSqrtP * finalSqrtP) / 1e18;
        uint256 ethFeesInUSD = (totalFeeETH * spotPrice) / 1e18;
        uint256 feeRatioPct = (ethFeesInUSD * 100) / totalFeeUSD;

        // ASSERTIONS: Both tokens must accumulate fees
        assertGt(totalFeeUSD, 0, "USD fees must accumulate");
        assertGt(totalFeeETH, 0, "ETH fees must accumulate");

        // ASSERTION: Fees must accumulate equally by value (within 10%)
        assertGe(feeRatioPct, 90, "Asymmetric fee accumulation detected (too low)");
        assertLe(feeRatioPct, 110, "Asymmetric fee accumulation detected (too high)");

        // ASSERTION: Price must stay within declared bounds
        assertTrue(
            finalSpotPrice >= 2000e18 && finalSpotPrice <= 4000e18,
            "AUDITOR CLAIM DISPROVEN: Price stays within bounds [2000-4000]"
        );
    }

    function test_DetailedFeeTracking_ReversedPattern() public {
        uint256 sqrtPriceMin = Math.sqrt(2000e18 * 1e18);
        uint256 sqrtPriceMax = Math.sqrt(4000e18 * 1e18);

        uint256 initialUSD = 3_000_000e18;
        uint256 initialETH = 1000e18;
        uint256 spotPrice = 3000e18;
        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            initialETH, initialUSD, Math.sqrt(spotPrice * 1e18), sqrtPriceMin, sqrtPriceMax
        );
        uint256 actualBalanceUSD = address(tokenUSD) > address(tokenETH) ? bGt : bLt;
        uint256 actualBalanceETH = address(tokenUSD) > address(tokenETH) ? bLt : bGt;

        (ISwapVM.Order memory mainOrder, bytes memory mainSig) = _createOrderWithBalances(
            actualBalanceUSD, actualBalanceETH, sqrtPriceMin, sqrtPriceMax, FLAT_FEE_BPS
        );
        bytes32 mainHash = swapVM.hash(mainOrder);

        vm.prank(taker);
        swapVM.swap(mainOrder, tokenETH, tokenUSD, 1e18, _takerData(false, mainSig));

        uint256 swapAmountETH = 0.3e18;
        uint256 roundsToTest = 10;
        uint256 totalFeeUSD = 0;
        uint256 totalFeeETH = 0;

        for (uint256 i = 0; i < roundsToTest; i++) {
            uint256 currentUSD = swapVM.balances(mainHash, tokenUSD);
            uint256 currentETH = swapVM.balances(mainHash, tokenETH);

            // First swap: exactOut (USD->ETH)
            (ISwapVM.Order memory snapshot1, bytes memory snap1Sig) = _createOrderWithBalances(
                currentUSD, currentETH, sqrtPriceMin, sqrtPriceMax, 0
            );
            bytes32 snap1Hash = swapVM.hash(snapshot1);

            vm.prank(taker);
            swapVM.swap(mainOrder, tokenUSD, tokenETH, swapAmountETH, _takerData(false, mainSig));
            vm.prank(taker);
            swapVM.swap(snapshot1, tokenUSD, tokenETH, swapAmountETH, _takerData(false, snap1Sig));

            uint256 mainUSD_after1 = swapVM.balances(mainHash, tokenUSD);
            uint256 mainETH_after1 = swapVM.balances(mainHash, tokenETH);
            uint256 snapUSD_after1 = swapVM.balances(snap1Hash, tokenUSD);
            uint256 snapETH_after1 = swapVM.balances(snap1Hash, tokenETH);

            int256 feeUSD_swap1 = int256(mainUSD_after1) - int256(snapUSD_after1);
            int256 feeETH_swap1 = int256(mainETH_after1) - int256(snapETH_after1);

            // Second swap: exactIn (ETH->USD)
            (ISwapVM.Order memory snapshot2, bytes memory snap2Sig) = _createOrderWithBalances(
                mainUSD_after1, mainETH_after1, sqrtPriceMin, sqrtPriceMax, 0
            );
            bytes32 snap2Hash = swapVM.hash(snapshot2);

            vm.prank(taker);
            swapVM.swap(mainOrder, tokenETH, tokenUSD, swapAmountETH, _takerData(true, mainSig));

            uint256 flatFeeAmount = swapAmountETH * FLAT_FEE_BPS / BPS;
            uint256 amountInAfterFee = swapAmountETH - flatFeeAmount;
            vm.prank(taker);
            swapVM.swap(snapshot2, tokenETH, tokenUSD, amountInAfterFee, _takerData(true, snap2Sig));

            uint256 mainUSD_after2 = swapVM.balances(mainHash, tokenUSD);
            uint256 mainETH_after2 = swapVM.balances(mainHash, tokenETH);
            uint256 snapUSD_after2 = swapVM.balances(snap2Hash, tokenUSD);
            uint256 snapETH_after2 = swapVM.balances(snap2Hash, tokenETH);

            int256 feeUSD_swap2 = int256(mainUSD_after2) - int256(snapUSD_after2);
            int256 feeETH_swap2 = int256(mainETH_after2) - int256(snapETH_after2);

            int256 roundFeeUSD = feeUSD_swap1 + feeUSD_swap2;
            int256 roundFeeETH = feeETH_swap1 + feeETH_swap2;

            totalFeeUSD += roundFeeUSD > 0 ? uint256(roundFeeUSD) : 0;
            totalFeeETH += roundFeeETH > 0 ? uint256(roundFeeETH) : 0;
        }

        // Final analysis
        uint256 usdFeesInETH = (totalFeeUSD * 1e18) / spotPrice;
        uint256 feeRatioPct = (usdFeesInETH * 100) / totalFeeETH;

        // ASSERTIONS: Both tokens must accumulate fees
        assertGt(totalFeeUSD, 0, "USD fees must accumulate in reversed pattern");
        assertGt(totalFeeETH, 0, "ETH fees must accumulate in reversed pattern");

        // ASSERTION: Fees must be symmetric by value (within 10%)
        assertGe(feeRatioPct, 90, "Reversed pattern: fee asymmetry detected (too low)");
        assertLe(feeRatioPct, 110, "Reversed pattern: fee asymmetry detected (too high)");
    }
}
