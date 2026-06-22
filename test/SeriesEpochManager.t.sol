// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../src/routers/LimitSwapVMRouter.sol";
import { LimitOpcodesDebug } from "../src/opcodes/LimitOpcodesDebug.sol";

import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { SeriesEpochManager, SeriesEpochManagerArgsBuilder } from "../src/instructions/SeriesEpochManager.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @title SeriesEpochManager tests
contract SeriesEpochManagerTest is Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    LimitSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    uint256 public makerPK = 0x1234;
    address public maker;

    uint256 public maker2PK = 0x5678;
    address public maker2;

    uint256 internal constant AMOUNT_IN = 1e15;

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) { }

    function setUp() public {
        maker = vm.addr(makerPK);
        maker2 = vm.addr(maker2PK);
        swapVM = new LimitSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        tokenB.mint(maker, 100e18);
        vm.prank(maker);
        tokenB.approve(address(swapVM), 100e18);
        tokenB.mint(maker2, 100e18);
        vm.prank(maker2);
        tokenB.approve(address(swapVM), 100e18);

        tokenA.mint(address(this), 100e18);
        tokenA.approve(address(swapVM), 100e18);
    }

    /// @dev Program: validate (seriesId, epoch) -> staticBalances -> limitSwap
    function _epochProgram(uint32 seriesId, uint32 epoch, uint64 salt) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_validateSeriesEpochXD, SeriesEpochManagerArgsBuilder.buildEpochValidation(seriesId, epoch)),
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([uint256(1e18), uint256(2e18)]))),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB))),
            p.build(_salt, abi.encodePacked(salt))
        );
    }

    function test_SeriesEpochManager_Counters() public {
        vm.startPrank(maker);

        assertEq(swapVM.seriesEpoch(maker, 0), 0);
        assertEq(swapVM.seriesEpoch(maker, 1), 0);

        swapVM.seriesEpochIncrease(1);

        assertEq(swapVM.seriesEpoch(maker, 0), 0);
        assertEq(swapVM.seriesEpoch(maker, 1), 1);

        swapVM.seriesEpochIncrease(2);

        assertEq(swapVM.seriesEpoch(maker, 0), 0);
        assertEq(swapVM.seriesEpoch(maker, 1), 1);

        swapVM.seriesEpochIncrease(1);

        assertEq(swapVM.seriesEpoch(maker, 0), 0);
        assertEq(swapVM.seriesEpoch(maker, 1), 2);

        swapVM.seriesEpochIncrease(0);

        assertEq(swapVM.seriesEpoch(maker, 0), 1);
        assertEq(swapVM.seriesEpoch(maker, 1), 2);

        swapVM.seriesEpochIncrease(1);

        assertEq(swapVM.seriesEpoch(maker, 0), 1);
        assertEq(swapVM.seriesEpoch(maker, 1), 3);

        swapVM.seriesEpochIncrease(0);

        assertEq(swapVM.seriesEpoch(maker, 0), 2);
        assertEq(swapVM.seriesEpoch(maker, 1), 3);

        swapVM.seriesEpochAdvance(0, 7);

        assertEq(swapVM.seriesEpoch(maker, 0), 9);
        assertEq(swapVM.seriesEpoch(maker, 1), 3);

        swapVM.seriesEpochAdvance(0, 7);

        assertEq(swapVM.seriesEpoch(maker, 0), 16);
        assertEq(swapVM.seriesEpoch(maker, 1), 3);

        swapVM.seriesEpochAdvance(1, 5);

        assertEq(swapVM.seriesEpoch(maker, 0), 16);
        assertEq(swapVM.seriesEpoch(maker, 1), 8);
    }

    function test_SeriesEpochManager_Basic() public {
        ISwapVM.Order memory orderA = _epochOrder(0, 1, 0); // series 0, epoch 1
        ISwapVM.Order memory orderB = _epochOrder(0, 2, 0); // series 0, epoch 2
        ISwapVM.Order memory orderC = _epochOrder(1, 2, 0); // series 0, epoch 2

        // series 0 - epoch 0
        // series 1 - epoch 0
        _tryExecute(orderA, false);
        _tryExecute(orderB, false);
        _tryExecute(orderC, false);

        vm.prank(maker);
        swapVM.seriesEpochIncrease(1);

        // series 0 - epoch 0
        // series 1 - epoch 1
        _tryExecute(orderA, false);
        _tryExecute(orderB, false);
        _tryExecute(orderC, false);

        vm.prank(maker);
        swapVM.seriesEpochIncrease(1);

        // series 0 - epoch 0
        // series 1 - epoch 2
        _tryExecute(orderA, false);
        _tryExecute(orderB, false);
        _tryExecute(orderC, true);

        vm.prank(maker);
        swapVM.seriesEpochIncrease(0);

        // series 0 - epoch 1
        // series 1 - epoch 2
        _tryExecute(orderA, true);
        _tryExecute(orderB, false);
        _tryExecute(orderC, true);

        vm.prank(maker);
        swapVM.seriesEpochIncrease(1);

        // series 0 - epoch 1
        // series 1 - epoch 3
        _tryExecute(orderA, true);
        _tryExecute(orderB, false);
        _tryExecute(orderC, false);

        vm.prank(maker);
        swapVM.seriesEpochIncrease(0);

        // series 0 - epoch 2
        // series 1 - epoch 3
        _tryExecute(orderA, false);
        _tryExecute(orderB, true);
        _tryExecute(orderC, false);

        vm.prank(maker);
        swapVM.seriesEpochIncrease(0);

        // series 0 - epoch 3
        // series 1 - epoch 3
        _tryExecute(orderA, false);
        _tryExecute(orderB, false);
        _tryExecute(orderC, false);
    }

    function testFuzz_SeriesEpochManager(uint256 ordersCount, uint8[17] memory seriesSeed, uint8[17] memory epochSeed, uint256 scheduleSeed) public {
        ordersCount = bound(ordersCount, 10, 17);

        ISwapVM.Order[] memory orders = new ISwapVM.Order[](ordersCount);
        uint8[] memory series = new uint8[](ordersCount);
        uint8[] memory epoch = new uint8[](ordersCount);
        for (uint256 i; i < ordersCount; i++) {
            series[i] = uint8(bound(seriesSeed[i], 0, 1));  // 2 series
            epoch[i] = uint8(bound(epochSeed[i], 1, 5));    // 5 distinct epochs live across orders
            orders[i] = _epochOrder(series[i], epoch[i], uint64(i));
        }

        uint256[2] memory epochCounter;

        assertEq(swapVM.seriesEpoch(maker, 0), 0);
        assertEq(swapVM.seriesEpoch(maker, 1), 0);

        // Epoch 0 in both series: nothing executable
        for (uint256 i; i < orders.length; i++) {
            _tryExecute(orders[i], false);
        }

        // Advance each series 0 -> 6, interleaved in a random order
        uint256 its = scheduleSeed % 16;
        scheduleSeed >>= 4;
        for (uint256 j; j < its; ++j) {
            ++epochCounter[scheduleSeed % 2];

            vm.prank(maker);
            swapVM.seriesEpochIncrease(scheduleSeed % 2);

            assertEq(swapVM.seriesEpoch(maker, 0), epochCounter[0]);
            assertEq(swapVM.seriesEpoch(maker, 1), epochCounter[1]);

            scheduleSeed >>= 1;

            for (uint256 i; i < orders.length; i++) {
                _tryExecute(orders[i], epochCounter[series[i]] == epoch[i]);
            }
        }

        // Advance epoch for all orders invalidation
        vm.prank(maker);
        swapVM.seriesEpochAdvance(0, 6);
        vm.prank(maker);
        swapVM.seriesEpochAdvance(1, 6);

        assertEq(swapVM.seriesEpoch(maker, 0), epochCounter[0] + 6);
        assertEq(swapVM.seriesEpoch(maker, 1), epochCounter[1] + 6);

        for (uint256 i; i < orders.length; i++) {
            _tryExecute(orders[i], false);
        }
    }

    function test_SeriesEpochManager_AdvanceBoundary_MinAmount() public {
        ISwapVM.Order memory orderAtZero = _epochOrder(0, 0, 0);
        ISwapVM.Order memory orderAtOne = _epochOrder(0, 1, 0);

        // series 0 - epoch 0
        _tryExecute(orderAtZero, true);
        _tryExecute(orderAtOne, false);

        vm.prank(maker);
        swapVM.seriesEpochAdvance(0, 1);

        assertEq(swapVM.seriesEpoch(maker, 0), 1);

        // series 0 - epoch 1
        _tryExecute(orderAtZero, false);
        _tryExecute(orderAtOne, true);
    }

    function test_SeriesEpochManager_AdvanceBoundary_MaxAmount() public {
        ISwapVM.Order memory orderAtZero = _epochOrder(0, 0, 0);
        ISwapVM.Order memory orderAt254 = _epochOrder(0, 254, 0);
        ISwapVM.Order memory orderAt255 = _epochOrder(0, 255, 0);

        // series 0 - epoch 0
        _tryExecute(orderAtZero, true);
        _tryExecute(orderAt254, false);
        _tryExecute(orderAt255, false);

        vm.prank(maker);
        swapVM.seriesEpochAdvance(0, 255);

        assertEq(swapVM.seriesEpoch(maker, 0), 255);

        // series 0 - epoch 255
        _tryExecute(orderAtZero, false);
        _tryExecute(orderAt254, false);
        _tryExecute(orderAt255, true);
    }

    function test_SeriesEpochManager_AdvanceZeroReverts() public {
        vm.prank(maker);
        vm.expectRevert(SeriesEpochManager.SeriesEpochManagerAdvanceEpochFailed.selector);
        swapVM.seriesEpochAdvance(0, 0);

        assertEq(swapVM.seriesEpoch(maker, 0), 0);
    }

    function test_SeriesEpochManager_SkipManyEpochsCancelsIntermediates() public {
        uint32[9] memory epochs = [uint32(1), 17, 64, 128, 200, 254, 255, 510, 513];

        ISwapVM.Order[] memory orders = new ISwapVM.Order[](epochs.length);
        for (uint256 i; i < epochs.length; i++) {
            orders[i] = _epochOrder(731, epochs[i], uint64(i));
            // series 0 - epoch 0: nothing is live yet
            _tryExecute(orders[i], false);
        }

        // Jump straight to epoch 255, skipping all the epochs in between
        vm.prank(maker);
        swapVM.seriesEpochAdvance(731, 255);

        assertEq(swapVM.seriesEpoch(maker, 731), 255);

        // Only the order pinned to the final epoch survives; every intermediate order is dead
        for (uint256 i; i < epochs.length; i++) {
            _tryExecute(orders[i], epochs[i] == 255);
        }

        vm.prank(maker);
        swapVM.seriesEpochAdvance(731, 255);

        assertEq(swapVM.seriesEpoch(maker, 731), 510);

        _tryExecute(orders[7], true);
        _tryExecute(orders[8], false);

        vm.prank(maker);
        swapVM.seriesEpochAdvance(731, 3);

        assertEq(swapVM.seriesEpoch(maker, 731), 513);

        _tryExecute(orders[7], false);
        _tryExecute(orders[8], true);
    }

    function test_SeriesEpochManager_DistinctMakers() public {
        // Both orders pinned to epoch 0 of series 0, one per maker
        ISwapVM.Order memory order1 = _epochOrderFor(maker, 755, 0, 0);
        ISwapVM.Order memory order2 = _epochOrderFor(maker2, 755, 0, 1);

        // Both makers start at epoch 0 -> both orders are live
        _tryExecute(order1, true);
        _tryExecute(order2, true);

        // Advance the first maker only
        vm.prank(maker);
        swapVM.seriesEpochAdvance(755, 1);

        assertEq(swapVM.seriesEpoch(maker, 755), 1);
        assertEq(swapVM.seriesEpoch(maker2, 755), 0);

        // First maker's order is now dead, second maker's order stays live
        _tryExecute(order1, false);
        _tryExecute(order2, true);

        // Advance the second maker too
        vm.prank(maker2);
        swapVM.seriesEpochAdvance(755, 1);

        assertEq(swapVM.seriesEpoch(maker, 755), 1);
        assertEq(swapVM.seriesEpoch(maker2, 755), 1);

        // Both makers have moved past epoch 0 -> both orders are dead
        _tryExecute(order1, false);
        _tryExecute(order2, false);
    }

    function _tryExecute(ISwapVM.Order memory order, bool shouldExecute) internal {
        bytes memory takerData = _takerData(_signOrder(order));
        if (shouldExecute) {
            (, uint256 amountOutQuote,) = swapVM.quote(order, address(tokenA), address(tokenB), AMOUNT_IN, takerData);
            (, uint256 amountOutSwap,) = swapVM.swap(order, address(tokenA), address(tokenB), AMOUNT_IN, takerData);
            assertEq(amountOutQuote, amountOutSwap);
            assertGt(amountOutSwap, 0);
        } else {
            vm.expectPartialRevert(SeriesEpochManager.SeriesEpochManagerWrongEpoch.selector);
            swapVM.quote(order, address(tokenA), address(tokenB), AMOUNT_IN, takerData);

            vm.expectPartialRevert(SeriesEpochManager.SeriesEpochManagerWrongEpoch.selector);
            vm.prank(address(this));
            swapVM.swap(order, address(tokenA), address(tokenB), AMOUNT_IN, takerData);
        }
    }

    function _signOrder(ISwapVM.Order memory order) internal view returns (bytes memory) {
        uint256 pk = order.maker == maker ? makerPK : maker2PK;
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _epochOrder(uint32 seriesId, uint32 epoch, uint64 salt) internal view returns (ISwapVM.Order memory) {
        return _epochOrderFor(maker, seriesId, epoch, salt);
    }

    function _epochOrderFor(address orderMaker, uint32 seriesId, uint32 epoch, uint64 salt) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: orderMaker,
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
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
            program: _epochProgram(seriesId, epoch, salt)
        }));
    }

    function _takerData(bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
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
            signature: signature
        }));
    }
}
