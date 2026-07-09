// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapRegisters } from "../src/libs/VM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { InvalidatorsArgsBuilder } from "../src/instructions/Invalidators.sol";
import { WhitelistArgsBuilder } from "../src/instructions/Whitelist.sol";
import { SeriesEpochManagerArgsBuilder } from "../src/instructions/SeriesEpochManager.sol";
import { DecayArgsBuilder } from "../src/instructions/Decay.sol";
import { PiecewiseLinearScaleBalanceIn, PiecewiseLinearScaleBalanceOut, PiecewiseLinearScale } from "../src/instructions/PiecewiseLinearScale.sol";
import { BaseFeeAdjusterArgsBuilder } from "../src/instructions/BaseFeeAdjuster.sol";
import { Stop, Revert, Jump, JumpIfDirection, JumpIfTokenIn, JumpIfTokenOut, Deadline, OnlyTakerTokenBalanceNonZero, OnlyTakerTokenBalanceGte, OnlyTakerTokenSupplyShareGte, OnlyTxOriginTokenBalanceNonZero, Salt } from "../src/instructions/Controls.sol";
import { MinRateArgsBuilder } from "../src/instructions/MinRate.sol";
import { DutchAuctionArgsBuilder } from "../src/instructions/DutchAuction.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { FeeArgsBuilderExperimental } from "../src/instructions/FeeExperimental.sol";
import { TWAPSwapArgsBuilder } from "../src/instructions/TWAPSwap.sol";
import { PeggedSwapArgsBuilder } from "../src/instructions/PeggedSwap.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { BestRouteSelector } from "../test/mocks/BestRouteSelector.sol";
import { Program, ProgramBuilder, Opcode } from "../test/utils/ProgramBuilder.sol";
import { dynamic } from "../test/utils/Dynamic.sol";

contract GasSnapshotE2E is Script {
    using ProgramBuilder for Program;

    uint256 internal constant AMOUNT = 1e18;

    uint256 internal constant MAKER_PK = 0xA11CE;
    uint256 internal constant TAKER_PK = 0xB0B;
    address internal maker;
    address internal taker;

    SwapVMRouterDebug internal swapVM;
    Aqua internal aqua;
    TokenMock internal tokenA;
    TokenMock internal tokenB;

    constructor() {}

    function run() external {
        maker = vm.addr(MAKER_PK);
        taker = vm.addr(TAKER_PK);

        _setUp();

        _label("_vmProgramJust");
        _fill(_vmProgramJust());

        _label("_vmProgramJustStaticBalances");
        _fill(_vmProgramJustStaticBalances());

        _label("_vmProgramJustDynamicBalances");
        _fill(_vmProgramJustDynamicBalances());

        _label("_vmProgramJustInvalidateBit");
        _fill(_vmProgramJustInvalidateBit());

        _label("_vmProgramJustInvalidateToken");
        _fill(_vmProgramJustInvalidateToken());

        _label("_vmProgramJustEpoch");
        _fill(_vmProgramJustEpoch());

        _label("_vmProgramJustPrivateOrder");
        _fill(_vmProgramJustPrivateOrder());

        _label("_vmProgramJustBaseFeeAdjuster");
        _fill(_vmProgramJustBaseFeeAdjuster());

        _label("_vmProgramJustJump");
        _fill(_vmProgramJustJump());

        _label("_vmProgramJustJumpIfTokenIn");
        _fill(_vmProgramJustJumpIfTokenIn());

        _label("_vmProgramJustDeadline");
        _fill(_vmProgramJustDeadline());

        _label("_vmProgramJustOnlyTakerTokenBalanceNonZero");
        _fill(_vmProgramJustOnlyTakerTokenBalanceNonZero());

        _label("_vmProgramJustOnlyTakerTokenBalanceGte");
        _fill(_vmProgramJustOnlyTakerTokenBalanceGte());

        _label("_vmProgramJustOnlyTakerTokenSupplyShareGte");
        _fill(_vmProgramJustOnlyTakerTokenSupplyShareGte());

        _label("_vmProgramJustSalt");
        _fill(_vmProgramJustSalt());

        _label("_vmProgramJustRequireMinRate");
        _fill(_vmProgramJustRequireMinRate());

        _label("_vmProgramJustFlatFeeAmountIn");
        _fill(_vmProgramJustFlatFeeAmountIn());

        _label("_vmProgramJustProgressiveFeeIn");
        _fill(_vmProgramJustProgressiveFeeIn());

        _label("_vmProgramJustPiecewiseLinearScaleBalanceIn");
        _fill(_vmProgramJustPiecewiseLinearScaleBalanceIn());

        _label("_vmProgramJustLimitSwap");
        _fill(_vmProgramJustLimitSwap());

        _label("_vmProgramJustLimitSwapFull");
        _fill(_vmProgramJustLimitSwapFull());

        _label("_vmProgramJustXYC");
        _fill(_vmProgramJustXYC());

        _label("_vmProgramJustXYCConcentrate");
        _fill(_vmProgramJustXYCConcentrate());

        _label("_vmProgramJustPeggedSwap");
        _fill(_vmProgramJustPeggedSwap());

        _label("_vmProgramLimitOrderSimple");
        _fill(_vmProgramLimitOrderSimple());

        _label("_vmProgramLimitOrderPrivate");
        _fill(_vmProgramLimitOrderPrivate());

        _label("_vmProgramLimitEpochPartial");
        _fill(_vmProgramLimitEpochPartial());

        _label("_vmProgramXYCSimple");
        _fill(_vmProgramXYCSimple());

        _label("_vmProgramXYCDecay");
        _fill(_vmProgramXYCDecay());
    }

    function _vmProgramJust() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustStaticBalances() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustDynamicBalances() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustInvalidateBit() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(15))
        );
    }

    function _vmProgramJustInvalidateToken() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(Opcode.InvalidateTokenIn)
        );
    }

    function _vmProgramJustEpoch() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(Opcode.ValidateSeriesEpoch, SeriesEpochManagerArgsBuilder.buildEpochValidation(10, 0))
        );
    }

    function _vmProgramJustPrivateOrder() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(Opcode.PrivateOrder, WhitelistArgsBuilder.buildPrivateOrder(taker))
        );
    }

    function _vmProgramJustBaseFeeAdjuster() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(Opcode.BaseFeeAdjuster, BaseFeeAdjusterArgsBuilder.build(25 gwei, 3500e18, 150_000, 99e16))
        );
    }

    function _vmProgramJustJump() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            Jump.build(uint16(4)),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustJumpIfTokenIn() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            JumpIfTokenIn.build(address(tokenA), 24),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustDeadline() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            Deadline.build(type(uint32).max)
        );
    }

    function _vmProgramJustOnlyTakerTokenBalanceNonZero() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            OnlyTakerTokenBalanceNonZero.build(address(tokenA))
        );
    }

    function _vmProgramJustOnlyTakerTokenBalanceGte() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            OnlyTakerTokenBalanceGte.build(address(tokenA), 1)
        );
    }

    function _vmProgramJustOnlyTakerTokenSupplyShareGte() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            OnlyTakerTokenSupplyShareGte.build(address(tokenA), 0)
        );
    }

    function _vmProgramJustSalt() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            Salt.build(uint64(42))
        );
    }

    function _vmProgramJustRequireMinRate() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.RequireMinRate, MinRateArgsBuilder.build(address(tokenA), address(tokenB), 1e18, 2.2e18)),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustFlatFeeAmountIn() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.FlatFeeAmountIn, FeeArgsBuilder.buildFlatFee(0.10e9)),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustProgressiveFeeIn() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.ProgressiveFeeIn, FeeArgsBuilderExperimental.buildProgressiveFee(0.10e9)),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustPiecewiseLinearScaleBalanceIn() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            PiecewiseLinearScaleBalanceIn.build(uint40(1700000000), dynamic([uint16(3600)]), dynamic([uint24(type(uint24).max), type(uint24).max / 2 + 1])),
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustLimitSwap() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramJustLimitSwapFull() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.LimitSwapFullAmount, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramJustXYC() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.XYCSwap)
        );
    }

    function _vmProgramJustXYCConcentrate() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(0.1e18, 5e18))
        );
    }

    function _vmProgramJustPeggedSwap() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.PatchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: 0, amountNetPulled: 0}))),
            p.build(Opcode.PeggedSwap, PeggedSwapArgsBuilder.build(PeggedSwapArgsBuilder.Args({x0: 50e18, y0: 50e18, linearWidth: 0.02e9, rateLt: 1, rateGt: 1})))
        );
    }

    function _vmProgramLimitOrderSimple() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(14)),
            p.build(Opcode.LimitSwapFullAmount, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramLimitOrderPrivate() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.PrivateOrder, WhitelistArgsBuilder.buildPrivateOrder(taker)),
            p.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(13)),
            p.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramLimitEpochPartial() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.ValidateSeriesEpoch, SeriesEpochManagerArgsBuilder.buildEpochValidation(55, 0)),
            p.build(Opcode.InvalidateTokenIn, InvalidatorsArgsBuilder.buildInvalidateBit(12)),
            p.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramXYCSimple() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(44)),
            p.build(Opcode.XYCSwap)
        );
    }

    function _vmProgramXYCDecay() internal pure returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.DynamicBalances, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(Opcode.InvalidateBit, InvalidatorsArgsBuilder.buildInvalidateBit(33)),
            p.build(Opcode.Decay, DecayArgsBuilder.build(155)),
            p.build(Opcode.XYCSwap)
        );
    }

    function _label(string memory label) internal {
        vm.broadcast();
        address(0x1066146).call(abi.encodeWithSignature("label(string)", label));
    }

    function _setUp() internal {
        vm.startBroadcast();

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenB, tokenA) = (tokenA, tokenB);

        aqua = new Aqua();
        swapVM = new SwapVMRouterDebug(address(aqua), address(0), maker, "SwapVM", "1.0.0");

        tokenA.mint(maker, type(uint192).max);
        tokenB.mint(maker, type(uint192).max);
        tokenA.mint(taker, type(uint192).max);
        tokenB.mint(taker, type(uint192).max);

        maker.call{ value: 1 ether }("");
        taker.call{ value: 1 ether }("");

        vm.stopBroadcast();

        vm.broadcast(MAKER_PK);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.broadcast(MAKER_PK);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.broadcast(TAKER_PK);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.broadcast(TAKER_PK);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _fill(bytes memory program) internal {
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

        vm.broadcast(TAKER_PK);
        swapVM.swap(order, AMOUNT, takerData);
    }
}
