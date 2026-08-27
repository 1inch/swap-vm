// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { StaticBalances, DynamicBalances } from "../../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapFullAmount } from "../../src/instructions/LimitSwap.sol";
import { InvalidateTokenIn, InvalidateBit } from "../../src/instructions/Invalidators.sol";
import { PrivateOrder } from "../../src/instructions/Whitelist.sol";
import { ValidateSeriesEpoch } from "../../src/instructions/SeriesEpochManager.sol";
import { BaseFeeAdjuster } from "../../src/instructions/BaseFeeAdjuster.sol";
import { Deadline, Salt } from "../../src/instructions/Controls.sol";
import { Jump, JumpIfTokenIn } from "../../src/instructions/Jumps.sol";
import { OnlyTakerTokenBalanceNonZero, OnlyTakerTokenBalanceGte, OnlyTakerTokenSupplyShareGte } from "../../src/instructions/TokenValidators.sol";
import { RequireMinRate, AdjustMinRate } from "../../src/instructions/MinRate.sol";
import { FeeFlatIn } from "../../src/instructions/FeeFlat.sol";
import { FeeProgressiveIn } from "../../src/instructions/FeeProgressive.sol";
import { PiecewiseLinearScaleBalanceIn } from "../../src/instructions/PiecewiseLinearScale.sol";
import { PeggedSwap } from "../../src/instructions/PeggedSwap.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCConcentrateSwap } from "../../src/instructions/XYCConcentrate.sol";
import { dynamic } from "../utils/Dynamic.sol";

/// @title OpcodeGas
/// @notice Per-opcode gas on prod `SwapVMRouter`.
/// @dev Just is StaticBalances + LimitSwap — a 1:1 fill used as the baseline.
///      Each opcode is appended to Just. Snapshot = lastCall(Just+op) − lastCall(Just)
///      + 4/16 of that opcode's encoding (not ABI padding of `order.data`).
///      First Just call warms slots so the subtracted baseline is hot.
contract OpcodeGas is Test {
    uint256 constant AMOUNT = 1e18;
    uint256 constant MAKER_PK = 0x1234;

    SwapVMRouter internal swapVM;
    TokenMock internal tokenA;
    TokenMock internal tokenB;
    address internal maker;
    address internal taker;
    uint256 internal justExec;
    bytes internal just;

    function setUp() public {
        maker = vm.addr(MAKER_PK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.mint(taker, 1e30);
        tokenB.mint(taker, 1e30);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_gas() public {
        just = bytes.concat(
            StaticBalances.build(AMOUNT, AMOUNT),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        // Cold Just, then hot Just — opcode runs are hot too.
        _measure(just);
        justExec = _measure(just);

        _snapshot("Jump", Jump.build(uint16(just.length + Jump.sizeOf(0))));
        _snapshot("JumpIfTokenIn", JumpIfTokenIn.build(address(tokenA), uint16(just.length + JumpIfTokenIn.sizeOf(address(0), 0))));
        _snapshot("Deadline", Deadline.build(type(uint32).max));
        _snapshot("OnlyTakerTokenBalanceNonZero", OnlyTakerTokenBalanceNonZero.build(address(tokenA)));
        _snapshot("OnlyTakerTokenBalanceGte", OnlyTakerTokenBalanceGte.build(address(tokenA), 1));
        _snapshot("OnlyTakerTokenSupplyShareGte", OnlyTakerTokenSupplyShareGte.build(address(tokenA), 0));
        _snapshot("StaticBalances", StaticBalances.build(AMOUNT, AMOUNT));
        _snapshot("DynamicBalances", DynamicBalances.build(AMOUNT, AMOUNT));
        _snapshot("InvalidateBit", InvalidateBit.build(15));
        _snapshot("InvalidateTokenIn", InvalidateTokenIn.build());
        _snapshot("XYCSwap", XYCSwap.build());
        _snapshot("XYCConcentrateSwap", XYCConcentrateSwap.build(0.1e18, 5e18));
        _snapshot("LimitSwap", LimitSwap.build(address(tokenA), address(tokenB)));
        _snapshot("LimitSwapFullAmount", LimitSwapFullAmount.build(address(tokenA), address(tokenB)));
        _snapshot("RequireMinRate", RequireMinRate.build(1e18, 2.2e18));
        _snapshot("AdjustMinRate", AdjustMinRate.build(1e18, 2.2e18));
        _snapshot("BaseFeeAdjuster", BaseFeeAdjuster.build(25 gwei, 3500e18, 150_000, 0.01e18));
        _snapshot("Salt", Salt.build(uint64(42)));
        _snapshot("FeeFlatIn", FeeFlatIn.build(0.10e7));
        _snapshot("FeeProgressiveIn", FeeProgressiveIn.build(0.10e7));
        _snapshot("PeggedSwap", PeggedSwap.build(50e18, 50e18, 0.02e9, 1, 1));
        _snapshot("ValidateSeriesEpoch", ValidateSeriesEpoch.build(10, 0));
        _snapshot("PrivateOrder", PrivateOrder.build(taker));
        _snapshot(
            "PiecewiseLinearScaleBalanceIn",
            PiecewiseLinearScaleBalanceIn.build(
                uint40(1700000000),
                dynamic([uint16(3600)]),
                dynamic([uint24(type(uint24).max), type(uint24).max / 2 + 1])
            )
        );
    }

    function _snapshot(string memory name, bytes memory opcode) private {
        uint256 opExecGas = _measure(bytes.concat(just, opcode));
        uint256 calldataGas;
        for (uint256 i; i < opcode.length; i++) {
            calldataGas += opcode[i] == 0 ? 4 : 16;
        }
        vm.snapshotValue("OpcodeGas", name, opExecGas - justExec + calldataGas);
    }

    function _measure(bytes memory program) private returns (uint256) {
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, swapVM.hash(order));
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            threshold: "",
            to: address(0),
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

        swapVM.swap(order, AMOUNT, takerData);
        return uint256(vm.lastCallGas().gasTotalUsed);
    }
}
