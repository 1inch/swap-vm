// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwapFullAmount } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { FeeBuilders } from "./utils/FeeBuilders.sol";

/// @notice LimitSwapFullAmount with one side of the order at zero balance:
///   balanceIn = 0 is a giveaway order (taker pays nothing, receives balanceOut),
///   balanceOut = 0 can never execute (takers cannot be forced to pay for nothing).
///   Also pins the FeeProtocol surplus-estimate fallback for zero opposite-side balance.
contract LimitSwapFullAmountOneSideZeroTest is Test {
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e31);
        tokenB.mint(maker, 1e31);
        tokenA.mint(taker, 1e31);
        tokenB.mint(taker, 1e31);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // === Zero balanceIn: giveaway order ===

    function test_FeeProtocol_ZeroBalanceIn_ExactIn() public {
        ISwapVM.Order memory order = _createOrder(_fullAmountProgram(0, 200e18), true);
        bytes memory exactInData = _makeTakerData(order, true, false);

        uint256 takerABefore = tokenA.balanceOf(taker);
        uint256 takerBBefore = tokenB.balanceOf(taker);
        uint256 makerBBefore = tokenB.balanceOf(maker);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 0, exactInData);

        assertEq(amountIn, 0, "Giveaway order takes no input");
        assertEq(amountOut, 200e18, "Giveaway order fills the whole balanceOut");
        assertEq(tokenA.balanceOf(taker), takerABefore, "Taker pays nothing");
        assertEq(tokenB.balanceOf(taker) - takerBBefore, 200e18, "Taker receives the full output");
        assertEq(makerBBefore - tokenB.balanceOf(maker), 200e18, "Maker gives the full output");
    }

    function test_FeeProtocol_ZeroBalanceIn_ExactIn_OverAsk() public {
        ISwapVM.Order memory order = _createOrder(_fullAmountProgram(0, 200e18), true);

        // Over-ask with partial fill allowed: input clamps to balanceIn = 0
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 5e18, _makeTakerData(order, true, true));
        assertEq(amountIn, 0);
        assertEq(amountOut, 200e18);

        // Without the partial fill flag the over-ask is a strict mismatch
        ISwapVM.Order memory order2 = _createOrder(_fullAmountProgram(0, 100e18), true);
        bytes memory strictData = _makeTakerData(order2, true, false);
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsTakerAmountInMismatch.selector, 5e18, 0));
        swapVM.swap(order2, 5e18, strictData);
    }

    function test_FeeProtocol_ZeroBalanceIn_ExactOut() public {
        ISwapVM.Order memory order = _createOrder(_fullAmountProgram(0, 200e18), true);
        bytes memory exactOutData = _makeTakerData(order, false, false);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, exactOutData);

        assertEq(amountIn, 0, "Giveaway order takes no input");
        assertEq(amountOut, 200e18, "Giveaway order fills the whole balanceOut");
    }

    function test_FeeProtocol_ZeroBalanceIn_ExactOut_Revert_UnderAsk() public {
        ISwapVM.Order memory order = _createOrder(_fullAmountProgram(0, 200e18), true);

        bytes memory exactOutData = _makeTakerData(order, false, false);

        // Full-amount order cannot be partially taken
        vm.expectRevert(abi.encodeWithSelector(LimitSwapFullAmount.LimitSwapAmountShouldCoverBalance.selector, 100e18, 200e18));
        swapVM.swap(order, 100e18, exactOutData);
    }

    function test_FeeProtocol_ZeroBalanceIn_Revert_WithoutAllowZeroAmountIn() public {
        ISwapVM.Order memory order = _createOrder(_fullAmountProgram(0, 200e18), false);

        bytes memory exactInData = _makeTakerData(order, true, false);

        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        swapVM.swap(order, 0, exactInData);
    }

    // === Zero balanceOut: order can never execute ===

    function test_FeeProtocol_ZeroBalanceOut_Reverts() public {
        ISwapVM.Order memory order = _createOrder(_fullAmountProgram(100e18, 0), true);

        bytes memory exactInData = _makeTakerData(order, true, false);
        bytes memory exactOutData = _makeTakerData(order, false, false);

        // ExactIn covering the full balanceIn still produces zero output
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swapVM.swap(order, 100e18, exactInData);

        // ExactOut of zero covers balanceOut = 0 but is rejected the same way
        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swapVM.swap(order, 0, exactOutData);
    }

    // === FeeProtocol surplus estimate with zero opposite-side balance ===

    /// @dev balanceIn = 0 makes the pro-rata scaling `estimatedOut * amountIn / balanceIn` a 0/0:
    ///   the fallback must use the full estimate, which is exact for a full-amount fill.
    ///   Maker gives 200e18 against a 240e18 estimate -> surplus 40e18, 10% fee = 4e18 paid by maker.
    function test_FeeProtocol_ZeroBalanceIn_SurplusOutFee_UsesFullEstimate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(0, 200e18),
            FeeBuilders.protocolSurplusOut(0.1e7, feeRecipient, 240e18),
            InvalidateTokenOut.build(),
            LimitSwapFullAmount.build(address(tokenA), address(tokenB))
        ), true);
        bytes memory exactOutData = _makeTakerData(order, false, false);

        uint256 takerBBefore = tokenB.balanceOf(taker);
        uint256 makerBBefore = tokenB.balanceOf(maker);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, exactOutData);

        assertEq(amountIn, 0);
        assertEq(amountOut, 200e18);
        assertEq(tokenB.balanceOf(taker) - takerBBefore, 200e18, "Taker receives the full output");
        assertEq(tokenB.balanceOf(feeRecipient), 4e18, "Surplus fee on the full estimate: (240e18 - 200e18) * 10%");
        assertEq(makerBBefore - tokenB.balanceOf(maker), 204e18, "Maker pays the output plus the surplus fee");
    }

    /// @dev balanceOut = 0 makes the pro-rata scaling `(estimatedIn * amountOut).ceilDiv(balanceOut)`
    ///   divide by zero: with the fallback the swap reaches taker validation and reverts with
    ///   a clean typed error instead of panic 0x12.
    function test_FeeProtocol_ZeroBalanceOut_SurplusInFee_RevertsCleanly() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 0),
            FeeBuilders.protocolSurplusIn(0.1e7, feeRecipient, 80e18),
            LimitSwapFullAmount.build(address(tokenA), address(tokenB))
        ), true);

        bytes memory exactInData = _makeTakerData(order, true, false);

        vm.expectRevert(abi.encodeWithSelector(TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector, 0));
        swapVM.swap(order, 100e18, exactInData);
    }

    // === Helpers ===

    function _fullAmountProgram(uint256 balanceIn, uint256 balanceOut) internal view returns (bytes memory) {
        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            LimitSwapFullAmount.build(address(tokenA), address(tokenB))
        );
    }

    function _createOrder(bytes memory program, bool allowZeroAmountIn) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: allowZeroAmountIn,
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

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn, bool allowPartialFill) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: allowPartialFill,
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
