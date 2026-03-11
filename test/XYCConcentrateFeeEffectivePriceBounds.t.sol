// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

/// @title XYCConcentrate Effective Price Bounds with Fees
/// @notice Tests that verify effective price ranges
///         when fees are applied on top of AMM price bounds.
///
/// @dev EXPECTED BEHAVIOR: This is standard AMM behavior. Price bounds [Pmin, Pmax]
///      apply to the AMM invariant curve, NOT to the final price paid by takers.
///      Takers always pay: AMM_price + fee_layer.

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { dynamic } from "./utils/Dynamic.sol";

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

contract XYCConcentrateFeeEffectivePriceBoundsTest is Test, OpcodesDebug {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    address public tokenUSD;
    address public tokenETH;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    uint32 public constant FEE_3PCT = 0.03e9; // 3%
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

    function _createOrder(
        uint256 balanceUSD,
        uint256 balanceETH,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory feeInstruction = feeBps > 0
            ? program.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeBps))
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

    /// @notice Test effective price at Pmin = 2000 with 3% fee
    /// @dev Auditor calculation: [1940 - 2062] effective range at Pmin
    function test_EffectivePriceAtPmin_3pctFee() public {
        uint256 Pmin = 2000e18;
        uint256 Pmax = 4000e18;
        uint256 sqrtPriceMin = Math.sqrt(Pmin * 1e18);
        uint256 sqrtPriceMax = Math.sqrt(Pmax * 1e18);

        // Position pool slightly above Pmin boundary to allow swaps
        uint256 targetSpotPrice = Pmin + 10e18; // 2010 USD/ETH
        uint256 initialUSD = 2_010_000e18;
        uint256 initialETH = 1000e18;

        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            initialETH, initialUSD, Math.sqrt(targetSpotPrice * 1e18), sqrtPriceMin, sqrtPriceMax
        );
        uint256 balanceUSD = address(tokenUSD) > address(tokenETH) ? bGt : bLt;
        uint256 balanceETH = address(tokenUSD) > address(tokenETH) ? bLt : bGt;

        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(
            balanceUSD, balanceETH, sqrtPriceMin, sqrtPriceMax, FEE_3PCT
        );

        // Test 1: Sell ETH for USD (ExactIn: sell exactly 1 ETH)
        // AMM price: 2000 USD/ETH
        // Expected effective: 2000 * 0.97 = 1940 USD/ETH (get less USD due to fee)
        uint256 ethToSell = 1e18;
        vm.prank(taker);
        (, uint256 usdReceived,) = swapVM.swap(order, tokenETH, tokenUSD, ethToSell, _takerData(true, sig));

        uint256 effectivePriceSell = (usdReceived * 1e18) / ethToSell;
        uint256 expectedPriceSell = (Pmin * 97) / 100; // 1940e18
        assertApproxEqRel(effectivePriceSell, expectedPriceSell, 0.01e18, "Sell price mismatch");

        // Test 2: Buy ETH with USD (ExactOut: get exactly 1 ETH)
        // AMM price: 2000 USD/ETH
        // Expected effective: 2000 / 0.97 = 2061.86 USD/ETH (pay more USD due to fee)
        uint256 ethToBuy = 1e18;
        vm.prank(taker);
        (uint256 usdPaid,,) = swapVM.swap(order, tokenUSD, tokenETH, ethToBuy, _takerData(false, sig));

        uint256 effectivePriceBuy = (usdPaid * 1e18) / ethToBuy;
        uint256 expectedPriceBuy = (Pmin * 100) / 97; // ~2061.86e18
        assertApproxEqRel(effectivePriceBuy, expectedPriceBuy, 0.01e18, "Buy price mismatch");
    }

    /// @notice Test effective price at Pmax = 4000 with 3% fee
    /// @dev Auditor calculation: [3880 - 4124] effective range at Pmax
    function test_EffectivePriceAtPmax_3pctFee() public {
        uint256 Pmin = 2000e18;
        uint256 Pmax = 4000e18;
        uint256 sqrtPriceMin = Math.sqrt(Pmin * 1e18);
        uint256 sqrtPriceMax = Math.sqrt(Pmax * 1e18);

        // Position pool exactly at Pmax boundary
        uint256 targetSpotPrice = Pmax;
        uint256 initialUSD = 4_000_000e18;
        uint256 initialETH = 1000e18;

        (, uint256 bLt, uint256 bGt) = XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
            initialETH, initialUSD, Math.sqrt(targetSpotPrice * 1e18), sqrtPriceMin, sqrtPriceMax
        );
        uint256 balanceUSD = address(tokenUSD) > address(tokenETH) ? bGt : bLt;
        uint256 balanceETH = address(tokenUSD) > address(tokenETH) ? bLt : bGt;

        (ISwapVM.Order memory order, bytes memory sig) = _createOrder(
            balanceUSD, balanceETH, sqrtPriceMin, sqrtPriceMax, FEE_3PCT
        );

        // Test 1: Sell ETH for USD (ExactIn: sell exactly 1 ETH)
        // AMM price: 4000 USD/ETH
        // Expected effective: 4000 * 0.97 = 3880 USD/ETH (get less USD due to fee)
        uint256 ethToSell = 1e18;
        vm.prank(taker);
        (, uint256 usdReceived,) = swapVM.swap(order, tokenETH, tokenUSD, ethToSell, _takerData(true, sig));

        uint256 effectivePriceSell = (usdReceived * 1e18) / ethToSell;
        uint256 expectedPriceSell = (Pmax * 97) / 100; // 3880e18
        assertApproxEqRel(effectivePriceSell, expectedPriceSell, 0.01e18, "Sell price mismatch");

        // Test 2: Buy ETH with USD (ExactOut: get exactly 1 ETH)
        // AMM price: 4000 USD/ETH
        // Expected effective: 4000 / 0.97 = 4123.71 USD/ETH (pay more USD due to fee)
        uint256 ethToBuy = 1e18;
        vm.prank(taker);
        (uint256 usdPaid,,) = swapVM.swap(order, tokenUSD, tokenETH, ethToBuy, _takerData(false, sig));

        uint256 effectivePriceBuy = (usdPaid * 1e18) / ethToBuy;
        uint256 expectedPriceBuy = (Pmax * 100) / 97; // ~4123.71e18
        assertApproxEqRel(effectivePriceBuy, expectedPriceBuy, 0.01e18, "Buy price mismatch");
    }
}
