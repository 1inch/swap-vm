// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { OraclePriceAdjuster } from "../../contracts/instructions/OraclePriceAdjuster.sol";
import { TokenMockDecimals } from "./mocks/TokenMockDecimals.sol";
import { PriceOracleMock } from "./mocks/PriceOracleMock.sol";

/**
 * @title OraclePriceAdjusterTest
 * @notice Tests for OraclePriceAdjuster on pairs whose tokens have different decimals
 * @dev The swap price is computed from raw token amounts, so an 18/6 pair prices 1e12 below the
 *      human-readable rate. These tests pin that the oracle answer is compared on that same scale.
 */
contract OraclePriceAdjusterTest is Test, OpcodesDebug {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;

    TokenMockDecimals public weth;
    TokenMockDecimals public usdc;
    address public tokenA;
    address public tokenB;
    bool public wethIsA;

    address public maker;
    uint256 public makerPK = 0x1234;

    uint8 public constant FEED_DECIMALS = 8;

    /// 3000 USDC per WETH, in each side's own decimals
    uint256 public constant WETH_RESERVE = 1000e18;
    uint256 public constant USDC_RESERVE = 3_000_000e6;

    /// One WETH in prices at exactly this, which is what makes the assertions exact
    uint256 public constant EXPECTED_OUT = 3000e6;

    function setUp() public {
        maker = vm.addr(makerPK);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        weth = new TokenMockDecimals("Wrapped Ether", "WETH", 18);
        usdc = new TokenMockDecimals("USD Coin", "USDC", 6);

        wethIsA = address(weth) < address(usdc);
        (tokenA, tokenB) = wethIsA ? (address(weth), address(usdc)) : (address(usdc), address(weth));

        weth.mint(maker, 10_000e18);
        usdc.mint(maker, 30_000_000e6);
        vm.prank(maker);
        weth.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        usdc.approve(address(swapVM), type(uint256).max);

        weth.mint(address(this), 10_000e18);
        weth.approve(address(swapVM), type(uint256).max);
        usdc.approve(address(swapVM), type(uint256).max);
    }

    /// Without the adjuster, one WETH buys 3000 USDC. Everything below is read against this.
    function test_OracleAdjusterBaselineWithoutOracle() public view {
        assertEq(_quoteOneWeth(_program(address(0), 0)), EXPECTED_OUT, "curve alone");
    }

    /// A feed quoting the same price the curve does leaves the swap alone. Before the decimals were
    /// part of the encoding this comparison ran 1e12 out and returned the cap instead.
    function test_OracleAdjusterDoesNotAdjustWhenFeedMatchesCurve() public {
        PriceOracleMock feed = new PriceOracleMock(3000e8, FEED_DECIMALS);
        assertEq(_quoteOneWeth(_program(address(feed), 0)), EXPECTED_OUT, "no adjustment");
    }

    /// A feed above the curve moves the swap to the feed price, not to the cap.
    function test_OracleAdjusterAppliesFeedPriceWhenBetter() public {
        PriceOracleMock feed = new PriceOracleMock(3150e8, FEED_DECIMALS);
        uint256 amountOut = _quoteOneWeth(_program(address(feed), 0));

        assertGt(amountOut, EXPECTED_OUT, "the taker gets the feed price");
        assertApproxEqRel(amountOut, 3150e6, 0.001e18, "and it is the feed price");
        assertLt(amountOut, EXPECTED_OUT * 2, "not the cap");
    }

    /// Adjustment stays one directional: a feed below the curve is ignored.
    function test_OracleAdjusterIgnoresWorseFeed() public {
        PriceOracleMock feed = new PriceOracleMock(2800e8, FEED_DECIMALS);
        assertEq(_quoteOneWeth(_program(address(feed), 0)), EXPECTED_OUT, "curve price kept");
    }

    /// maxPriceDecay still caps the adjustment.
    function test_OracleAdjusterRespectsTheCap() public {
        PriceOracleMock feed = new PriceOracleMock(6000e8, FEED_DECIMALS);
        // maxIncrease = 2e18 - 0.9e18 = 1.1e18
        uint256 amountOut = _quoteOneWeth(_program(address(feed), 0.9e18));

        assertEq(amountOut, (EXPECTED_OUT * 1.1e18) / 1e18, "capped at 10 percent");
    }

    /// Scaling is exact on both sides of the exponent, including 18/18 where it is the old 1e18 rescale.
    function test_ScaleAnswerMatchesTheRawUnitConvention() public pure {
        assertEq(OraclePriceAdjuster.scaleAnswer(3000e8, 8, 18, 6), 3000e6, "18 in, 6 out");
        assertEq(OraclePriceAdjuster.scaleAnswer(3000e8, 8, 6, 18), 3000e8 * 10 ** 22, "6 in, 18 out");
        assertEq(OraclePriceAdjuster.scaleAnswer(3000e8, 8, 18, 18), 3000e8 * 10 ** 10, "18 and 18");
    }

    // --- helpers -----------------------------------------------------------------------------

    function _program(address feed, uint64 maxPriceDecay) private view returns (bytes memory) {
        bytes memory bytecode = bytes.concat(
            wethIsA
                ? StaticBalances.build(WETH_RESERVE, USDC_RESERVE)
                : StaticBalances.build(USDC_RESERVE, WETH_RESERVE),
            LimitSwap.build(address(weth), address(usdc))
        );

        if (feed == address(0)) return bytecode;

        return bytes.concat(
            bytecode,
            OraclePriceAdjuster.build(maxPriceDecay, 3600, FEED_DECIMALS, 18, 6, feed)
        );
    }

    function _quoteOneWeth(bytes memory program) private view returns (uint256 amountOut) {
        ISwapVM.Order memory order = _createOrder(program);
        (, amountOut,) = swapVM.asView().quote(order, 1e18, _signAndPackTakerData(order));
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
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

    function _signAndPackTakerData(ISwapVM.Order memory order) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: wethIsA,
            allowPartialFill: false,
            threshold: "",
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
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
