// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { DynamicBalances, StaticBalances } from "../../contracts/instructions/Balances.sol";
import { PeggedSwap } from "../../contracts/instructions/PeggedSwap.sol";
import { FeeFlatOut } from "../../contracts/instructions/FeeFlat.sol";
import { TokenMockDecimals } from "./mocks/TokenMockDecimals.sol";

contract PeggedSwapBuilder {
    function build(uint144 anchorA, uint144 anchorB, uint104 width) external pure returns (bytes memory) {
        return PeggedSwap.build(anchorA, anchorB, width);
    }
}

contract PeggedSwapTest is Test {
    uint256 private constant MAKER_PK = 0x1234;
    uint104 private constant WIDTH = 0.8e27;
    uint104 private constant TIGHT_WIDTH = 100e27;

    SwapVMRouter private swapVM;
    TraitsHelper private orders;
    TokenMock private tokenA;
    TokenMock private tokenB;
    address private maker;
    address private taker;

    struct Pool {
        address tokenA;
        address tokenB;
        uint256 balanceA;
        uint256 balanceB;
        uint144 anchorA;
        uint144 anchorB;
        uint104 width;
        uint24 feeOutBps;
    }

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        taker = makeAddr("taker");
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        _fundAndApprove(tokenA, 1e30);
        _fundAndApprove(tokenB, 1e30);
    }

    function test_StandardPeg_ExactInBothDirections() public view {
        ISwapVM.Order memory order = _standardOrder(0);
        uint256 amountIn = 100e18;

        (uint256 amountInAToB, uint256 amountOutAToB) = _quote(order, amountIn, true, true, false);
        (uint256 amountInBToA, uint256 amountOutBToA) = _quote(order, amountIn, true, false, false);

        assertEq(amountInAToB, amountIn);
        assertEq(amountInBToA, amountIn);
        assertLe(amountOutAToB, amountIn);
        assertLe(amountOutBToA, amountIn);
        assertGe(amountOutAToB, amountIn * 99 / 100);
        assertGe(amountOutBToA, amountIn * 99 / 100);
    }

    function test_StandardPeg_ExactOutBothDirections() public view {
        ISwapVM.Order memory order = _standardOrder(0);
        uint256 amountOut = 100e18;

        (uint256 amountInAToB, uint256 amountOutAToB) = _quote(order, amountOut, false, true, false);
        (uint256 amountInBToA, uint256 amountOutBToA) = _quote(order, amountOut, false, false, false);

        assertEq(amountOutAToB, amountOut);
        assertEq(amountOutBToA, amountOut);
        assertGe(amountInAToB, amountOut);
        assertGe(amountInBToA, amountOut);
        assertLe(amountInAToB, amountOut * 101 / 100);
        assertLe(amountInBToA, amountOut * 101 / 100);
    }

    function test_StandardPeg_QuoteMatchesSwap() public {
        ISwapVM.Order memory order = _standardOrder(0);
        (uint256 quotedIn, uint256 quotedOut) = _quote(order, 100e18, true, true, false);
        (uint256 swappedIn, uint256 swappedOut) = _swap(order, 100e18, true, true, false);

        assertEq(swappedIn, quotedIn);
        assertEq(swappedOut, quotedOut);
    }

    function test_RatedPeg_ExactInBothDirections() public {
        (ISwapVM.Order memory order, address eurc, address usdc) = _ratedOrder();
        bool eurcToUsdc = eurc < usdc;

        (uint256 eurcIn, uint256 usdcOut) = _quote(order, 100e6, true, eurcToUsdc, false);
        (uint256 usdcIn, uint256 eurcOut) = _quote(order, 112e9, true, !eurcToUsdc, false);

        assertEq(eurcIn, 100e6);
        assertEq(usdcIn, 112e9);
        _assertExactInNearRate(usdcOut, 112e9);
        _assertExactInNearRate(eurcOut, 100e6);
    }

    function test_RatedPeg_ExactOutBothDirections() public {
        (ISwapVM.Order memory order, address eurc, address usdc) = _ratedOrder();
        bool eurcToUsdc = eurc < usdc;

        (uint256 eurcIn, uint256 usdcOut) = _quote(order, 112e9, false, eurcToUsdc, false);
        (uint256 usdcIn, uint256 eurcOut) = _quote(order, 100e6, false, !eurcToUsdc, false);

        assertEq(usdcOut, 112e9);
        assertEq(eurcOut, 100e6);
        _assertExactOutNearRate(eurcIn, 100e6);
        _assertExactOutNearRate(usdcIn, 112e9);
    }

    function test_RatedPeg_QuoteMatchesSwap() public {
        (ISwapVM.Order memory order, address eurc, address usdc) = _ratedOrder();
        bool eurcToUsdc = eurc < usdc;

        (uint256 quotedIn, uint256 quotedOut) = _quote(order, 100e6, true, eurcToUsdc, false);
        (uint256 swappedIn, uint256 swappedOut) = _swap(order, 100e6, true, eurcToUsdc, false);

        assertEq(swappedIn, quotedIn);
        assertEq(swappedOut, quotedOut);
    }

    function test_ExactOutPositiveOutputAlwaysChargesInput() public view {
        ISwapVM.Order memory order = _standardOrder(0);

        (uint256 amountIn, uint256 amountOut) = _quote(order, 1, false, true, false);

        assertEq(amountOut, 1);
        assertGt(amountIn, 0);
    }

    function testFuzz_FeeGrowthMaintainsMonotonicity(
        uint144 anchor,
        uint16 growth,
        uint104 width,
        uint256 amount,
        bool isAToB
    ) public view {
        anchor = uint144(bound(anchor, 1e18, 1e30));
        growth = uint16(bound(growth, 1, 1_000));
        width = uint104(bound(width, 0.25e27, 5_000e27));
        uint256 balance = uint256(anchor) * growth;
        amount = bound(amount, 1e6, balance / 10);

        Pool memory pool = _standardPool(0);
        pool.balanceA = balance;
        pool.balanceB = balance;
        pool.anchorA = anchor;
        pool.anchorB = anchor;
        pool.width = width;

        ISwapVM.Order memory order = _order(pool);
        (, uint256 amountOut) = _quote(order, amount, true, isAToB, false);
        (, uint256 amountOutPlusOne) = _quote(order, amount + 1, true, isAToB, false);
        (uint256 amountIn,) = _quote(order, amount, false, isAToB, false);
        (uint256 amountInPlusOne,) = _quote(order, amount + 1, false, isAToB, false);

        assertLe(amountOut, amountOutPlusOne);
        assertLe(amountIn, amountInPlusOne);
    }

    function test_ExactInPartialFillDrainsOutputReserve() public {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1_000e18;
        pool.balanceB = 1_000e18;
        pool.anchorA = 1_000e18;
        pool.anchorB = 1_000e18;
        ISwapVM.Order memory order = _order(pool);
        uint256 requestedIn = 100_000e18;

        (uint256 amountIn, uint256 amountOut) = _swap(order, requestedIn, true, true, true);

        assertLt(amountIn, requestedIn);
        assertEq(amountOut, pool.balanceB);
    }

    function test_Revert_ExactInRoundingUnderflowReturnsZeroOutput() public {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1e27 - 1;
        pool.balanceB = 1e27 - 1;
        pool.anchorA = 1e27;
        pool.anchorB = 1e27;
        ISwapVM.Order memory order = _order(pool);
        bytes memory takerData = _takerData(order, true, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        quoter.quote(order, 1, takerData);
    }

    function test_ExactOutPartialFillCapsOutputAtReserve() public view {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1_000e18;
        pool.balanceB = 1_000e18;
        pool.anchorA = 1_000e18;
        pool.anchorB = 1_000e18;

        (uint256 amountIn, uint256 amountOut) = _quote(_order(pool), 100_000e18, false, true, true);

        assertGt(amountIn, 0);
        assertEq(amountOut, pool.balanceB);
    }

    function test_FeeOutReducesOutput() public view {
        ISwapVM.Order memory orderWithoutFee = _standardOrder(0);
        ISwapVM.Order memory orderWithFee = _standardOrder(uint24(FeeFlatOut.BPS >> 2));

        (, uint256 amountOutWithoutFee) = _quote(orderWithoutFee, 100e18, true, true, false);
        (, uint256 amountOutWithFee) = _quote(orderWithFee, 100e18, true, true, false);

        assertLt(amountOutWithFee, amountOutWithoutFee);
        assertLe(amountOutWithFee, amountOutWithoutFee * 3 / 4);
    }

    function test_WidthControlsSlippage() public view {
        Pool memory curvedPool = _standardPool(0);
        curvedPool.width = 0.25e27;
        Pool memory tightPool = _standardPool(0);
        tightPool.width = 5_000e27;

        (, uint256 curvedOut) = _quote(_order(curvedPool), 1_000e18, true, true, false);
        (, uint256 tightOut) = _quote(_order(tightPool), 1_000e18, true, true, false);

        assertGt(tightOut, curvedOut);
        assertLe(tightOut, 1_000e18);
        assertGe(tightOut, 999.9e18);
    }

    function test_Revert_ContextOverflow() public {
        bytes memory program = bytes.concat(
            StaticBalances.build(uint256(1) << 144, 10_000e18),
            PeggedSwap.build(10_000e18, 10_000e18, WIDTH)
        );
        ISwapVM.Order memory order = _order(address(tokenA), address(tokenB), program);
        bytes memory takerData = _takerData(order, true, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(PeggedSwap.PeggedSwapContextOverflow.selector);
        quoter.quote(order, 1e18, takerData);
    }

    function test_Revert_ContributionOverflow() public {
        Pool memory pool = _standardPool(0);
        pool.balanceA = 1e30;
        pool.balanceB = 1e30;
        pool.anchorA = 1e18;
        pool.anchorB = 1e18;
        pool.width = 5_000e27;
        ISwapVM.Order memory order = _order(pool);
        bytes memory takerData = _takerData(order, false, true, false);
        ISwapVM quoter = swapVM.asView();

        vm.expectRevert(PeggedSwap.PeggedSwapContextOverflow.selector);
        quoter.quote(order, 1, takerData);
    }

    function test_BuildValidation() public {
        PeggedSwapBuilder builder = new PeggedSwapBuilder();

        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidAnchors.selector, 0, 1));
        builder.build(0, 1, WIDTH);

        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidAnchors.selector, 1, 0));
        builder.build(1, 0, WIDTH);

        uint104 invalidWidth = uint104(0.25e27 - 1);
        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidWidth.selector, invalidWidth));
        builder.build(1, 1, invalidWidth);

        invalidWidth = uint104(5_000e27 + 1);
        vm.expectRevert(abi.encodeWithSelector(PeggedSwap.PeggedSwapInvalidWidth.selector, invalidWidth));
        builder.build(1, 1, invalidWidth);

        assertEq(builder.build(1, 1, 0.25e27).length, PeggedSwap.sizeOf());
        assertEq(builder.build(1, 1, 5_000e27).length, PeggedSwap.sizeOf());
    }

    function _standardOrder(uint24 feeOutBps) private view returns (ISwapVM.Order memory) {
        return _order(_standardPool(feeOutBps));
    }

    function _standardPool(uint24 feeOutBps) private view returns (Pool memory) {
        return Pool({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            balanceA: 10_000e18,
            balanceB: 10_000e18,
            anchorA: 10_000e18,
            anchorB: 10_000e18,
            width: WIDTH,
            feeOutBps: feeOutBps
        });
    }

    function _ratedOrder() private returns (ISwapVM.Order memory order, address eurc, address usdc) {
        TokenMock eurcToken = new TokenMockDecimals("EURC", "EURC", 6);
        TokenMock usdcToken = new TokenMockDecimals("USDC", "USDC", 9);
        eurc = address(eurcToken);
        usdc = address(usdcToken);
        _fundAndApprove(eurcToken, 1_000_000e6);
        _fundAndApprove(usdcToken, 1_120_000e9);

        bool eurcIsA = eurc < usdc;
        order = _order(Pool({
            tokenA: eurcIsA ? eurc : usdc,
            tokenB: eurcIsA ? usdc : eurc,
            balanceA: eurcIsA ? 10_000e6 : 11_200e9,
            balanceB: eurcIsA ? 11_200e9 : 10_000e6,
            anchorA: eurcIsA ? 10_000e6 : 11_200e9,
            anchorB: eurcIsA ? 11_200e9 : 10_000e6,
            width: TIGHT_WIDTH,
            feeOutBps: 0
        }));
    }

    function _order(Pool memory pool) private view returns (ISwapVM.Order memory) {
        bytes memory program = bytes.concat(
            DynamicBalances.build(pool.balanceA, pool.balanceB),
            pool.feeOutBps == 0 ? bytes("") : FeeFlatOut.build(pool.feeOutBps),
            PeggedSwap.build(pool.anchorA, pool.anchorB, pool.width)
        );
        return _order(pool.tokenA, pool.tokenB, program);
    }

    function _order(address tokenLt, address tokenGt, bytes memory program) private view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            receiver: address(0),
            tokenA: tokenLt,
            tokenB: tokenGt,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
            allowZeroAmountIn: false,
            program: program
        }));
    }

    function _quote(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill
    ) private view returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut,) = swapVM.asView().quote(
            order,
            amount,
            _takerData(order, isExactIn, isAToB, allowPartialFill)
        );
    }

    function _swap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill
    ) private returns (uint256 amountIn, uint256 amountOut) {
        bytes memory takerData = _takerData(order, isExactIn, isAToB, allowPartialFill);
        vm.prank(taker);
        (amountIn, amountOut,) = swapVM.swap(order, amount, takerData);
    }

    function _takerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        bool isAToB,
        bool allowPartialFill
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, orderHash);

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: true,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: allowPartialFill,
            usePermit2: false,
            threshold: "",
            to: address(0),
            hasPreTransferInCallback: false,
            signature: abi.encodePacked(r, s, v)
        }));
    }

    function _fundAndApprove(TokenMock token, uint256 amount) private {
        token.mint(maker, amount);
        token.mint(taker, amount);
        vm.prank(maker);
        token.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        token.approve(address(swapVM), type(uint256).max);
    }

    function _assertExactInNearRate(uint256 actualOut, uint256 idealOut) private pure {
        assertLe(actualOut, idealOut);
        assertGe(actualOut, idealOut * 999 / 1000);
    }

    function _assertExactOutNearRate(uint256 actualIn, uint256 idealIn) private pure {
        assertGe(actualIn, idealIn);
        assertLe(actualIn, idealIn * 1001 / 1000);
    }
}
