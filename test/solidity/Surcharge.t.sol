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
import { InvalidateTokenIn, InvalidateTokenOut } from "../../contracts/instructions/Invalidators.sol";
import { DutchAuctionBalanceIn, DutchAuctionBalanceOut } from "../../contracts/instructions/DutchAuction.sol";
import { PiecewiseLinearSurchargeBalanceIn, PiecewiseLinearSurchargeBalanceOut } from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { BaseFeeAdjusterBalanceIn, BaseFeeAdjusterBalanceOut } from "../../contracts/instructions/BaseFeeAdjuster.sol";

contract SurchargeTest is Test, OpcodesDebug {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    uint256 private constant MAKER_PRIVATE_KEY = 0x1234;
    address private maker;

    function setUp() public {
        maker = vm.addr(MAKER_PRIVATE_KEY);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.startPrank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function testFuzz_Surcharge_DutchAuction_MakerReceiveAtLeast(
        uint256 balanceIn,
        uint256 balanceOut,
        uint40[3] memory timestamps
    ) public {
        balanceIn = bound(balanceIn, 10, 1e30);
        balanceOut = bound(balanceOut, 10, 1e30);
        timestamps[0] = uint40(bound(timestamps[0], 0, 198));
        timestamps[1] = uint40(bound(timestamps[1], timestamps[0] + 1, 199));
        timestamps[2] = uint40(bound(timestamps[2], timestamps[1] + 1, 200));

        vm.fee(type(uint64).max);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            DutchAuctionBalanceIn.build(0, 0.999e18, 0.1e7),
            InvalidateTokenOut.build(),
            BaseFeeAdjusterBalanceIn.build(0, type(uint96).max, type(uint24).max),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactOutData = _signAndPackTakerData(order, false);

        tokenA.mint(address(this), balanceIn * 2);
        uint256 makerBalanceBefore = tokenA.balanceOf(maker);
        vm.warp(timestamps[0]);
        swapVM.swap(order, balanceOut / 5, exactOutData);
        vm.warp(timestamps[1]);
        swapVM.swap(order, balanceOut / 3, exactOutData);
        vm.warp(timestamps[2]);
        swapVM.swap(order, balanceOut - balanceOut / 5 - balanceOut / 3, exactOutData);

        assertGe(tokenA.balanceOf(maker) - makerBalanceBefore, balanceIn);
    }

    function testFuzz_Surcharge_DutchAuction_MakerSpendAtMost(
        uint256 balanceIn,
        uint256 balanceOut,
        uint40[3] memory timestamps
    ) public {
        balanceOut = bound(balanceOut, 10, 1e30);
        balanceIn = bound(balanceIn, 10, balanceOut);
        timestamps[0] = uint40(bound(timestamps[0], 0, 198));
        timestamps[1] = uint40(bound(timestamps[1], timestamps[0] + 1, 199));
        timestamps[2] = uint40(bound(timestamps[2], timestamps[1] + 1, 200));

        vm.fee(type(uint64).max);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            DutchAuctionBalanceOut.build(0, 0.999e18, 0.1e7),
            InvalidateTokenIn.build(),
            BaseFeeAdjusterBalanceOut.build(0, type(uint96).max, type(uint24).max),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactInData = _signAndPackTakerData(order, true);

        tokenA.mint(address(this), balanceIn);
        uint256 makerBalanceBefore = tokenB.balanceOf(maker);
        vm.warp(timestamps[0]);
        swapVM.swap(order, balanceIn / 5, exactInData);
        vm.warp(timestamps[1]);
        swapVM.swap(order, balanceIn / 3, exactInData);
        vm.warp(timestamps[2]);
        swapVM.swap(order, balanceIn - balanceIn / 5 - balanceIn / 3, exactInData);

        assertLe(makerBalanceBefore - tokenB.balanceOf(maker), balanceOut);
    }

    function testFuzz_Surcharge_PiecewiseLinearSurcharge_MakerReceiveAtLeast(
        uint256 balanceIn,
        uint256 balanceOut,
        uint40[3] memory timestamps
    ) public {
        balanceIn = bound(balanceIn, 10, 1e30);
        balanceOut = bound(balanceOut, 10, 1e30);
        timestamps[0] = uint40(bound(timestamps[0], 0, 178));
        timestamps[1] = uint40(bound(timestamps[1], timestamps[0] + 1, 179));
        timestamps[2] = uint40(bound(timestamps[2], timestamps[1] + 1, 180));

        uint16[] memory durations = new uint16[](1);
        durations[0] = 177;
        uint24[] memory scales = new uint24[](2);
        scales[0] = 2 << 22;
        scales[1] = 0;

        vm.fee(type(uint64).max);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            PiecewiseLinearSurchargeBalanceIn.build(0, durations, scales),
            InvalidateTokenOut.build(),
            BaseFeeAdjusterBalanceIn.build(0, type(uint96).max, type(uint24).max),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactOutData = _signAndPackTakerData(order, false);

        tokenA.mint(address(this), balanceIn * 2);
        uint256 makerBalanceBefore = tokenA.balanceOf(maker);
        vm.warp(timestamps[0]);
        swapVM.swap(order, balanceOut / 5, exactOutData);
        vm.warp(timestamps[1]);
        swapVM.swap(order, balanceOut / 3, exactOutData);
        vm.warp(timestamps[2]);
        swapVM.swap(order, balanceOut - balanceOut / 5 - balanceOut / 3, exactOutData);

        assertGe(tokenA.balanceOf(maker) - makerBalanceBefore, balanceIn);
    }

    function testFuzz_Surcharge_PiecewiseLinearSurcharge_MakerSpendAtMost(
        uint256 balanceIn,
        uint256 balanceOut,
        uint40[3] memory timestamps
    ) public {
        balanceOut = bound(balanceOut, 10, 1e30);
        balanceIn = bound(balanceIn, 10, balanceOut);
        timestamps[0] = uint40(bound(timestamps[0], 0, 178));
        timestamps[1] = uint40(bound(timestamps[1], timestamps[0] + 1, 179));
        timestamps[2] = uint40(bound(timestamps[2], timestamps[1] + 1, 180));

        uint16[] memory durations = new uint16[](1);
        durations[0] = 177;
        uint24[] memory scales = new uint24[](2);
        scales[0] = 2 << 22;
        scales[1] = 0;

        vm.fee(type(uint64).max);

        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            PiecewiseLinearSurchargeBalanceOut.build(0, durations, scales),
            InvalidateTokenIn.build(),
            BaseFeeAdjusterBalanceOut.build(0, type(uint96).max, type(uint24).max),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory exactInData = _signAndPackTakerData(order, true);

        tokenA.mint(address(this), balanceIn);
        uint256 makerBalanceBefore = tokenB.balanceOf(maker);
        vm.warp(timestamps[0]);
        swapVM.swap(order, balanceIn / 5, exactInData);
        vm.warp(timestamps[1]);
        swapVM.swap(order, balanceIn / 3, exactInData);
        vm.warp(timestamps[2]);
        swapVM.swap(order, balanceIn - balanceIn / 5 - balanceIn / 3, exactInData);

        assertLe(makerBalanceBefore - tokenB.balanceOf(maker), balanceOut);
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
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

    function _signAndPackTakerData(ISwapVM.Order memory order, bool isExactIn) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            usePermit2: false,
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
