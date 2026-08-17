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
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { PiecewiseLinearScaleBalanceIn, PiecewiseLinearScaleBalanceOut } from "../src/instructions/PiecewiseLinearScale.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../src/instructions/BaseFeeAdjuster.sol";
import { FulfillBonusBalanceIn, FulfillBonusBalanceOut } from "../src/instructions/FulfillBonus.sol";
import { BalanceScaleCutIn, BalanceScaleCutOut } from "../src/instructions/BalanceScaleCut.sol";

/**
 * @title BalanceScaleCutTest
 * @notice Tests for BalanceScaleCutIn / BalanceScaleCutOut instructions
 * @dev Maker-favor rate guard on the balance registers: whatever PiecewiseLinearScale,
 *   BaseFeeAdjuster and FulfillBonus spend, the offered rate never crosses rateIn / rateOut.
 *   The reference is the opposite (unmodified) balance, so the guard survives partial-fill
 *   rescaling by invalidators and stays consistent between exact-in and exact-out queries.
 *
 *   Order used everywhere below: 100e18 tokenA in -> 200e18 tokenB out (A->B).
 *   Guard rate 9/20: floor balanceIn 90e18, cap balanceOut 222222222222222222222.
 *   PLS auctions run over 1000s: BalanceIn scale 1.0 -> 0.5, BalanceOut scale 0.5 -> 1.0.
 */
contract BalanceScaleCutTest is Test {
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint40 constant START = 1_000_000;
    uint64 constant RATE_A = 9;
    uint64 constant RATE_B = 20;
    uint256 constant CAP_OUT = 222222222222222222222; // 100e18 * 20 / 9

    uint24 constant SCALE_ONE = type(uint24).max; // 1.0
    uint24 constant SCALE_HALF = 8388607;         // 0.5

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

        vm.warp(START);
        vm.fee(1 gwei);
    }

    // === CutIn: PLS sources funds by discounting balanceIn, guard floors it at 90e18 ===

    function test_CutIn_AuctionStart_Inactive() public {
        ISwapVM.Order memory order = _cutInOrder("", RATE_A, RATE_B);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 100e18, "No funds sourced yet, plain rate");
        assertEq(amountOut, 200e18);

        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 100e18);
        assertEq(amountOut, 200e18);
    }

    function test_CutIn_MidAuction_WithinBudget_Passthrough() public {
        // Looser guard 7/20 (floor 70e18) does not touch the mid-auction 75e18
        ISwapVM.Order memory order = _cutInOrder("", 7, RATE_B);
        vm.warp(START + 500);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));

        assertEq(amountIn, 75e18, "PLS rate passes through untouched");
        assertEq(amountOut, 200e18);
    }

    function test_CutIn_MidAuction_Clamped() public {
        // PLS mid scale 0.75 -> 75e18 is below the 90e18 floor
        ISwapVM.Order memory order = _cutInOrder("", RATE_A, RATE_B);
        vm.warp(START + 500);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 90e18, "Fulfillment clamped to the reserve rate");
        assertEq(amountOut, 200e18);

        (amountIn, amountOut,) = swapVM.swap(order, 90e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 90e18, "Exact-in settles on the same clamped curve");
        assertEq(amountOut, 200e18);

        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 45e18, "Partial fill priced at the reserve rate");
        assertEq(amountOut, 100e18);
    }

    function test_CutIn_AuctionEnd_Clamped() public {
        // PLS last scale 0.5 -> 50e18, guard holds the reserve
        ISwapVM.Order memory order = _cutInOrder("", RATE_A, RATE_B);
        vm.warp(START + 5000);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));

        assertEq(amountIn, 90e18, "Auction never sells below the reserve rate");
        assertEq(amountOut, 200e18);
    }

    function test_CutIn_BaseFeeAdjuster_WithinBudget() public {
        // 5e18 gas discount on the plain 100e18 stays above the floor
        ISwapVM.Order memory order = _cutInOrder(_adjusterIn(5e22), RATE_A, RATE_B);
        vm.fee(2 gwei);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));

        assertEq(amountIn, 95e18, "Gas discount fully funded");
        assertEq(amountOut, 200e18);
    }

    function test_CutIn_BaseFeeAdjuster_Clamped() public {
        // 20e18 gas discount would breach the floor, guard cuts it to 10e18
        ISwapVM.Order memory order = _cutInOrder(_adjusterIn(2e23), RATE_A, RATE_B);
        vm.fee(2 gwei);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));

        assertEq(amountIn, 90e18, "Gas discount limited to the sourced funds");
        assertEq(amountOut, 200e18);
    }

    function test_CutIn_Stacked_AllAdjusters() public {
        // PLS 1.0 + 4e18 gas discount + 5% fulfill bonus: 100 -> 96 -> 91.2, above the floor
        bytes memory adjusters = bytes.concat(_adjusterIn(4e22), FulfillBonusBalanceIn.build(0.05e7));
        ISwapVM.Order memory order = _cutInOrder(adjusters, RATE_A, RATE_B);
        vm.fee(2 gwei);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 91.2e18, "All adjustments funded at auction start");
        assertEq(amountOut, 200e18);

        (amountIn, amountOut,) = swapVM.swap(order, 91.2e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 91.2e18, "Exact-in settles on the same stacked curve");
        assertEq(amountOut, 200e18);

        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 48e18, "Partial fill: gas discount only, no bonus");
        assertEq(amountOut, 100e18);

        // Mid auction 75 -> 71 -> 67.45 breaches the floor, all spends cut back to it
        vm.warp(START + 500);
        (amountIn, amountOut,) = swapVM.swap(order, 200e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 90e18, "Stacked adjustments limited to the sourced funds");
        assertEq(amountOut, 200e18);
    }

    /// @dev The guard reference is the invalidator-rescaled balanceOut, so split fills
    ///   settle at the same clamped rate and fully consume the order at the reserve totals
    function test_CutIn_SplitFills_KeepMinRate() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            InvalidateTokenOut.build(),
            _plsIn(),
            BalanceScaleCutIn.build(RATE_A, RATE_B),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        vm.warp(START + 500);

        (uint256 in1, uint256 out1,) = swapVM.swap(order, 100e18, _makeTakerData(order, false, false));
        (uint256 in2, uint256 out2,) = swapVM.swap(order, 150e18, _makeTakerData(order, false, true));

        assertEq(in1, 45e18, "First half at the reserve rate");
        assertEq(out1, 100e18);
        assertEq(in2, 45e18, "Second half at the reserve rate");
        assertEq(out2, 100e18);
        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), 200e18);
    }

    /// @dev rateA / rateB are token-sorted like RequireMinRate: B->A swap flips them
    function test_CutIn_ReverseDirection_RatesSorted() public {
        // 200e18 tokenB in -> 100e18 tokenA out, floor balanceIn = 100e18 * 9 / 5 = 180e18
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            _plsIn(),
            BalanceScaleCutIn.build(5, 9),
            LimitSwap.build(address(tokenB), address(tokenA))
        ));
        vm.warp(START + 500);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, _takerData(order, false, false, false));

        assertEq(amountIn, 180e18, "Floor derived from the token-sorted rates");
        assertEq(amountOut, 100e18);
    }

    /// @dev Whatever the time, gas price, bonus and ask, the maker min rate always holds
    function testFuzz_CutIn_MakerMinRateInvariant(uint256 timeDelta, uint256 basefee, uint256 incentive, uint256 ask, bool isExactIn) public {
        vm.warp(START + bound(timeDelta, 0, 2000));
        vm.fee(bound(basefee, 0, 100 gwei));
        incentive = bound(incentive, 0, 0.5e7);
        ask = bound(ask, 1e15, 400e18);

        bytes memory adjusters = bytes.concat(_adjusterIn(5e22), FulfillBonusBalanceIn.build(uint24(incentive)));
        ISwapVM.Order memory order = _cutInOrder(adjusters, RATE_A, RATE_B);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, ask, _makeTakerData(order, isExactIn, true));

        assertGe(amountIn * RATE_B, amountOut * RATE_A, "Maker min rate must hold");
    }

    // === CutOut: PLS sources funds by growing balanceOut, guard caps it at 222.22e18 ===

    function test_CutOut_AuctionStart_WithinBudget() public {
        // Scale 0.5 -> balanceOut 100e18, 20% fulfill bonus grosses up to 125e18, below the cap
        ISwapVM.Order memory order = _cutOutOrder(FulfillBonusBalanceOut.build(0.2e7), RATE_A, RATE_B);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, true, false));

        assertEq(amountIn, 100e18);
        assertEq(amountOut, 125e18, "Bonus fully funded at auction start");
    }

    function test_CutOut_AuctionEnd_Bonus_Clamped() public {
        // Scale 1.0 -> 200e18, 20% bonus targets 250e18, guard caps at the reserve
        ISwapVM.Order memory order = _cutOutOrder(FulfillBonusBalanceOut.build(0.2e7), RATE_A, RATE_B);
        vm.warp(START + 5000);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, true, false));

        assertEq(amountIn, 100e18);
        assertEq(amountOut, CAP_OUT, "Bonus limited to the sourced funds");
    }

    function test_CutOut_AuctionEnd_BaseFee_Clamped() public {
        // 50e18 gas premium on 200e18 targets 250e18, guard caps at the reserve
        ISwapVM.Order memory order = _cutOutOrder(_adjusterOut(5e23), RATE_A, RATE_B);
        vm.warp(START + 5000);
        vm.fee(2 gwei);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, true, false));
        assertEq(amountIn, 100e18);
        assertEq(amountOut, CAP_OUT, "Gas premium limited to the sourced funds");

        // Partial exact-out at the capped rate: ceil rounding keeps the maker whole
        (amountIn, amountOut,) = swapVM.swap(order, 100e18, _makeTakerData(order, false, false));
        assertEq(amountIn, 45000000000000000001, "Partial fill priced at the capped rate");
        assertEq(amountOut, 100e18);
        assertGe(amountIn * RATE_B, amountOut * RATE_A);
    }

    /// @dev The all-or-nothing bonus checks its own gross-up, not the capped one: an exact-out
    ///   ask of the capped amount is not a bonus fulfillment and settles at the plain balance.
    ///   Maker-favored, and the min rate holds
    function test_CutOut_ExactOut_CappedAsk_SettlesPlain() public {
        ISwapVM.Order memory order = _cutOutOrder(FulfillBonusBalanceOut.build(0.2e7), RATE_A, RATE_B);
        vm.warp(START + 5000);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, CAP_OUT, _makeTakerData(order, false, true));

        assertEq(amountIn, 100e18);
        assertEq(amountOut, 200e18, "Ask below the bonus gross-up fulfills plain");
        assertGe(amountIn * RATE_B, amountOut * RATE_A);
    }

    /// @dev Whatever the time, gas price, bonus and ask, the maker min rate always holds
    function testFuzz_CutOut_MakerMinRateInvariant(uint256 timeDelta, uint256 basefee, uint256 incentive, uint256 ask, bool isExactIn) public {
        vm.warp(START + bound(timeDelta, 0, 2000));
        vm.fee(bound(basefee, 0, 100 gwei));
        incentive = bound(incentive, 0, 0.6e7);
        ask = bound(ask, 1e15, 400e18);

        bytes memory adjusters = bytes.concat(_adjusterOut(5e23), FulfillBonusBalanceOut.build(uint24(incentive)));
        ISwapVM.Order memory order = _cutOutOrder(adjusters, RATE_A, RATE_B);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, ask, _makeTakerData(order, isExactIn, true));

        assertGe(amountIn * RATE_B, amountOut * RATE_A, "Maker min rate must hold");
    }

    // === Build validation ===

    function buildCutInExternal(uint64 rateA, uint64 rateB) external pure returns (bytes memory) {
        return BalanceScaleCutIn.build(rateA, rateB);
    }

    function buildCutOutExternal(uint64 rateA, uint64 rateB) external pure returns (bytes memory) {
        return BalanceScaleCutOut.build(rateA, rateB);
    }

    function test_Build_Reverts() public {
        vm.expectRevert(BalanceScaleCutIn.BalanceScaleCutRateZero.selector);
        this.buildCutInExternal(0, RATE_B);

        vm.expectRevert(BalanceScaleCutIn.BalanceScaleCutRateZero.selector);
        this.buildCutInExternal(RATE_A, 0);

        vm.expectRevert(BalanceScaleCutOut.BalanceScaleCutRateZero.selector);
        this.buildCutOutExternal(0, RATE_B);

        vm.expectRevert(BalanceScaleCutOut.BalanceScaleCutRateZero.selector);
        this.buildCutOutExternal(RATE_A, 0);
    }

    // === Helpers ===

    /// @dev Dutch auction on the input balance: scale 1.0 -> 0.5 over 1000s
    function _plsIn() internal pure returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        durations[0] = 1000;
        uint24[] memory scales = new uint24[](2);
        scales[0] = SCALE_ONE;
        scales[1] = SCALE_HALF;
        return PiecewiseLinearScaleBalanceIn.build(START, durations, scales);
    }

    /// @dev Dutch auction on the output balance: scale 0.5 -> 1.0 over 1000s
    function _plsOut() internal pure returns (bytes memory) {
        uint16[] memory durations = new uint16[](1);
        durations[0] = 1000;
        uint24[] memory scales = new uint24[](2);
        scales[0] = SCALE_HALF;
        scales[1] = SCALE_ONE;
        return PiecewiseLinearScaleBalanceOut.build(START, durations, scales);
    }

    /// @dev 1 gwei base, 100k gas: discount = (basefee - 1 gwei) * 1e5 * ethPrice / 1e18
    function _adjusterIn(uint96 ethPrice) internal pure returns (bytes memory) {
        return BaseFeeAdjusterBalanceIn.build(uint64(1 gwei), ethPrice, 100000, 0.5e7);
    }

    function _adjusterOut(uint96 ethPrice) internal pure returns (bytes memory) {
        return BaseFeeAdjusterBalanceOut.build(uint64(1 gwei), ethPrice, 100000, 0.5e7);
    }

    function _cutInOrder(bytes memory adjusters, uint64 rateA, uint64 rateB) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            _plsIn(),
            adjusters,
            BalanceScaleCutIn.build(rateA, rateB),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
    }

    function _cutOutOrder(bytes memory adjusters, uint64 rateA, uint64 rateB) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(100e18, 200e18),
            _plsOut(),
            adjusters,
            BalanceScaleCutOut.build(rateA, rateB),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
    }

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn, bool allowPartialFill) internal view returns (bytes memory) {
        return _takerData(order, isExactIn, allowPartialFill, true);
    }

    function _takerData(ISwapVM.Order memory order, bool isExactIn, bool allowPartialFill, bool isAToB) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
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
