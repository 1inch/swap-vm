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

    uint256 internal constant AMOUNT_IN = 1e15;

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) { }

    function setUp() public {
        maker = vm.addr(makerPK);
        swapVM = new LimitSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
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

    function test_EpochManager_Counters() public {
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

    function test_EpochManager_Basic() public {
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

    function testFuzz_EpochManager(uint256 ordersCount, uint8[17] memory seriesSeed, uint8[17] memory epochSeed, uint256 scheduleSeed) public {
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

    function _tryExecute(ISwapVM.Order memory order, bool shouldExecute) internal {
        bytes memory takerData = _takerData();
        if (shouldExecute) {
            (, uint256 amountOut,) = swapVM.quote(order, address(tokenA), address(tokenB), AMOUNT_IN, takerData);
            assertGt(amountOut, 0);
        } else {
            vm.expectPartialRevert(SeriesEpochManager.SeriesEpochManagerWrongEpoch.selector);
            swapVM.quote(order, address(tokenA), address(tokenB), AMOUNT_IN, takerData);
        }
    }

    function _epochOrder(uint32 seriesId, uint32 epoch, uint64 salt) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
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

    function _takerData() internal view returns (bytes memory) {
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
            signature: ""
        }));
    }
}
