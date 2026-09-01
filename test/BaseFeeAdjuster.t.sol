// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { InvalidateTokenOut } from "../src/instructions/Invalidators.sol";
import { DutchAuctionBalanceOut } from "../src/instructions/DutchAuction.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../src/instructions/BaseFeeAdjuster.sol";

/**
 * @title BaseFeeAdjusterTest
 * @notice Tests for BaseFeeAdjusterBalanceIn / BaseFeeAdjusterBalanceOut instructions
 * @dev Balance modifiers granting the taker a gas-based rate adjustment: above baseGasPrice
 *   the input balance is discounted (or the output balance grossed up) by the reference
 *   gas cost, capped by capBps of the balance. Placed before the swap opcode; the taker
 *   captures the adjustment pro-rata to the filled share of the (remaining) balance.
 *
 *   Order used everywhere below: 300000e18 tokenB in -> 100e18 tokenA out (B->A, rate 3000:1),
 *   base 20 gwei, gasAmount 150k. At 100 gwei the reference gas cost is
 *   (100-20) gwei * 150k = 0.012 ETH = 36e18 tokenB (at 3000e18) = 0.012e18 tokenA (at 1e18).
 */
contract BaseFeeAdjusterTest is Test, OpcodesDebug {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint64 constant BASE_GAS_PRICE = 20 gwei;
    uint96 constant ETH_PRICE_IN_B = 3000e18; // tokenB per ETH (input side)
    uint96 constant ETH_PRICE_IN_A = 1e18;    // tokenA per ETH (output side)
    uint24 constant GAS_AMOUNT = 150_000;

    uint256 constant BALANCE_IN_B = 300000e18;
    uint256 constant BALANCE_OUT_A = 100e18;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        tokenA.mint(taker, 1e30);
        tokenB.mint(taker, 1e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _balanceInOrder(uint24 capBps) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_OUT_A, BALANCE_IN_B),
            BaseFeeAdjusterBalanceIn.build(BASE_GAS_PRICE, ETH_PRICE_IN_B, GAS_AMOUNT, capBps),
            LimitSwap.build(address(tokenB), address(tokenA))
        ));
    }

    function _balanceOutOrder(uint24 capBps) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_OUT_A, BALANCE_IN_B),
            BaseFeeAdjusterBalanceOut.build(BASE_GAS_PRICE, ETH_PRICE_IN_A, GAS_AMOUNT, capBps),
            LimitSwap.build(address(tokenB), address(tokenA))
        ));
    }

    /**
     * Output improves (or stays capped) as gas grows
     */
    function test_BalanceIn_GasVariations() public {
        ISwapVM.Order memory order = _balanceInOrder(0.01e7); // 1% cap
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256[] memory gasPrices = new uint256[](4);
        gasPrices[0] = 20 gwei;
        gasPrices[1] = 50 gwei;
        gasPrices[2] = 100 gwei;
        gasPrices[3] = 200 gwei;

        uint256 previousOut;
        for (uint256 i = 0; i < gasPrices.length; i++) {
            vm.fee(gasPrices[i]);
            (, uint256 quotedOut,) = swapVM.asView().quote(order, 3000e18, exactInData);

            assertGe(quotedOut, previousOut, "Higher gas should improve or maintain price");
            previousOut = quotedOut;
        }
    }

    /**
     * No adjustment at or below the base gas price
     */
    function test_BalanceIn_NoAdjustmentBelowBase() public {
        ISwapVM.Order memory order = _balanceInOrder(0.01e7);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(10 gwei);
        (, uint256 outputLowGas,) = swapVM.asView().quote(order, 3000e18, exactInData);

        vm.fee(BASE_GAS_PRICE);
        (, uint256 outputBaseGas,) = swapVM.asView().quote(order, 3000e18, exactInData);

        assertEq(outputLowGas, outputBaseGas, "No adjustment below base gas");
        assertEq(outputLowGas, 1e18, "Should be the plain order rate");
    }

    /**
     * A full fill captures exactly the whole gas discount off the input
     */
    function test_BalanceIn_FullFill_ExactDiscount() public {
        ISwapVM.Order memory order = _balanceInOrder(0.1e7); // 10% cap, not binding
        bytes memory exactOutData = _signAndPackTakerData(order, false, 0);

        vm.fee(100 gwei); // reference gas cost = 36e18 tokenB
        (uint256 quotedIn,,) = swapVM.asView().quote(order, BALANCE_OUT_A, exactOutData);

        assertEq(quotedIn, BALANCE_IN_B - 36e18, "Full fill pays balanceIn minus the full gas discount");
    }

    /**
     * A partial fill captures the discount pro-rata: the discount improves the rate of the
     * whole balance, so a 1% fill captures ~1% of it (no dust-fill discount extraction)
     */
    function test_BalanceIn_PartialFill_ProRataDiscount() public {
        ISwapVM.Order memory order = _balanceInOrder(0.1e7);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(100 gwei);
        (, uint256 quotedOut,) = swapVM.asView().quote(order, 3000e18, exactInData);

        // Rate of the discounted balance: amountOut = amountIn * balanceOut / (balanceIn - 36e18)
        assertEq(quotedOut, 3000e18 * BALANCE_OUT_A / (BALANCE_IN_B - 36e18), "Discounted limit rate");

        // 1% fill captures ~1% of the 36e18 discount (~0.36e18 tokenB worth = ~0.00012e18 tokenA)
        assertGt(quotedOut, 1e18, "Better than the plain rate");
        assertLt(quotedOut, 1.0002e18, "Far below the full discount");
    }

    /**
     * The discount is capped by capBps of the input balance
     */
    function test_BalanceIn_CapBinds() public {
        ISwapVM.Order memory order = _balanceInOrder(0.001e7); // 0.1% cap = 300e18 tokenB
        bytes memory exactOutData = _signAndPackTakerData(order, false, 0);

        vm.fee(1000 gwei); // reference gas cost = 441e18 tokenB > cap
        (uint256 quotedIn,,) = swapVM.asView().quote(order, BALANCE_OUT_A, exactOutData);

        assertEq(quotedIn, BALANCE_IN_B - 300e18, "Discount capped at 0.1% of balanceIn");
    }

    /**
     * BalanceOut variant: the premium is added to the output balance (eth price in token out)
     */
    function test_BalanceOut_FullFill_ExactPremium() public {
        ISwapVM.Order memory order = _balanceOutOrder(0.1e7); // 10% cap, not binding
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(100 gwei); // reference gas cost = 0.012e18 tokenA
        (, uint256 quotedOut,) = swapVM.asView().quote(order, BALANCE_IN_B, exactInData);

        assertEq(quotedOut, BALANCE_OUT_A + 0.012e18, "Full fill receives balanceOut plus the full gas premium");
    }

    /**
     * BalanceOut premium is capped so it never exceeds capBps of the adjusted balance
     */
    function test_BalanceOut_CapBinds() public {
        uint24 capBps = 0.00001e7; // max premium = balanceOut * cap / (BPS - cap) ~ 0.001% of balance
        ISwapVM.Order memory order = _balanceOutOrder(capBps);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.fee(100 gwei); // reference gas cost 0.012e18 tokenA > cap
        (, uint256 quotedOut,) = swapVM.asView().quote(order, BALANCE_IN_B, exactInData);

        uint256 maxPremium = BALANCE_OUT_A * capBps / (1e7 - capBps);
        assertLt(maxPremium, 0.012e18, "Sanity: cap must bind");
        assertEq(quotedOut, BALANCE_OUT_A + maxPremium, "Premium capped by capBps of the balance");
    }

    /**
     * With InvalidateTokenOut the discount applies to the remaining balance per fill:
     * each fill is compensated pro-rata to its share of the remaining order
     */
    function test_BalanceIn_Multifill_PerFillDiscount() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_OUT_A, BALANCE_IN_B),
            InvalidateTokenOut.build(),
            BaseFeeAdjusterBalanceIn.build(BASE_GAS_PRICE, ETH_PRICE_IN_B, GAS_AMOUNT, 0.1e7),
            LimitSwap.build(address(tokenB), address(tokenA))
        ));
        bytes memory exactOutData = _signAndPackTakerData(order, false, 0);

        vm.fee(100 gwei);

        // First fill: half the output at the discounted rate: 50e18 * 299964e18 / 100e18
        (uint256 in1,,) = swapVM.swap(order, 50e18, exactOutData);
        assertEq(in1, 149982e18, "Half fill at the discounted rate");

        // Second fill drains the remainder: remaining balanceIn 150000e18 minus the full 36e18 again
        (uint256 in2,,) = swapVM.swap(order, 50e18, exactOutData);
        assertEq(in2, 150000e18 - 36e18, "Drain fill captures the full discount of the remaining order");

        // Each fill is compensated for its own gas: two fills capture 18e18 + 36e18 in total
        assertEq(BALANCE_IN_B - in1 - in2, 54e18, "Per-fill gas compensation");
    }

    /**
     * Composes with DutchAuction: both modify balances before the swap
     */
    function test_BalanceIn_WithDutchAuction() public {
        uint40 startTime = uint40(block.timestamp);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_OUT_A, BALANCE_IN_B),
            DutchAuctionBalanceOut.build(startTime, 300, 0.999e18),
            BaseFeeAdjusterBalanceIn.build(BASE_GAS_PRICE, ETH_PRICE_IN_B, GAS_AMOUNT, 0.01e7),
            LimitSwap.build(address(tokenB), address(tokenA))
        ));
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256[] memory timeOffsets = new uint256[](3);
        timeOffsets[0] = 0;
        timeOffsets[1] = 150;
        timeOffsets[2] = 299;

        for (uint256 t = 0; t < timeOffsets.length; t++) {
            vm.warp(startTime + timeOffsets[t]);

            vm.fee(30 gwei);
            (, uint256 outModerate,) = swapVM.asView().quote(order, 3000e18, exactInData);
            assertGt(outModerate, 0, "Should get positive output");

            vm.fee(100 gwei);
            (, uint256 outHigh,) = swapVM.asView().quote(order, 3000e18, exactInData);
            assertGe(outHigh, outModerate, "Higher gas should improve the price at any auction stage");
        }
    }

    function buildBalanceInExternal(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) external pure returns (bytes memory) {
        return BaseFeeAdjusterBalanceIn.build(baseGasPrice, ethPrice, gasAmount, capBps);
    }

    function buildBalanceOutExternal(uint64 baseGasPrice, uint96 ethPrice, uint24 gasAmount, uint24 capBps) external pure returns (bytes memory) {
        return BaseFeeAdjusterBalanceOut.build(baseGasPrice, ethPrice, gasAmount, capBps);
    }

    function test_Build_CapOutOfRange_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BaseFeeAdjusterBalanceIn.BaseFeeAdjusterCapOutOfRange.selector, uint24(1e7)));
        this.buildBalanceInExternal(BASE_GAS_PRICE, ETH_PRICE_IN_B, GAS_AMOUNT, 1e7);

        vm.expectRevert(abi.encodeWithSelector(BaseFeeAdjusterBalanceOut.BaseFeeAdjusterCapOutOfRange.selector, uint24(1e7)));
        this.buildBalanceOutExternal(BASE_GAS_PRICE, ETH_PRICE_IN_A, GAS_AMOUNT, 1e7);
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
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
            isAToB: false,
            allowPartialFill: false,
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
