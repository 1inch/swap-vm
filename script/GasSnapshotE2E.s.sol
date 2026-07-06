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
import { PiecewiseLinearScaleArgsBuilder } from "../src/instructions/PiecewiseLinearScale.sol";
import { Program, ProgramBuilder } from "../test/utils/ProgramBuilder.sol";
import { dynamic } from "../test/utils/Dynamic.sol";

contract GasSnapshotE2E is Script, OpcodesDebug {
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

    constructor() OpcodesDebug(address(0)) {}

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

        _label("_vmProgramJustLimitSwap");
        _fill(_vmProgramJustLimitSwap());

        _label("_vmProgramJustLimitSwapFull");
        _fill(_vmProgramJustLimitSwapFull());

        _label("_vmProgramJustXYC");
        _fill(_vmProgramJustXYC());

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

    function _vmProgramJust() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustStaticBalances() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustDynamicBalances() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_dynamicBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0})))
        );
    }

    function _vmProgramJustInvalidateToken() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(_invalidateTokenIn1D)
        );
    }

    function _vmProgramJustInvalidateBit() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(15))
        );
    }

    function _vmProgramJustEpoch() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(_validateSeriesEpochXD, SeriesEpochManagerArgsBuilder.buildEpochValidation(10, 0))
        );
    }

    function _vmProgramJustPrivateOrder() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_patchSwapRegisters, abi.encode(SwapRegisters({balanceIn: AMOUNT, balanceOut: AMOUNT, amountIn: AMOUNT, amountOut: AMOUNT, amountNetPulled: 0}))),
            p.build(_whitelistSingleTaker, WhitelistArgsBuilder.buildWhitelistSingleTaker(taker))
        );
    }

    function _vmProgramJustLimitSwap() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramJustLimitSwapFull() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramJustXYC() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_dynamicBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_xycSwapXD)
        );
    }

    function _vmProgramLimitOrderSimple() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(14)),
            p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramLimitOrderPrivate() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_whitelistSingleTaker, WhitelistArgsBuilder.buildWhitelistSingleTaker(taker)),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(13)),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramLimitEpochPartial() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_validateSeriesEpochXD, SeriesEpochManagerArgsBuilder.buildEpochValidation(55, 0)),
            p.build(_invalidateTokenIn1D, InvalidatorsArgsBuilder.buildInvalidateBit(12)),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmProgramXYCSimple() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_dynamicBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(44)),
            p.build(_xycSwapXD)
        );
    }

    function _vmProgramXYCDecay() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_dynamicBalancesXD, BalancesArgsBuilder.build([uint256(1e18), 1e18])),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(33)),
            p.build(_decayXD, DecayArgsBuilder.build(155)),
            p.build(_xycSwapXD)
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

        tokenA.mint(maker, type(uint224).max);
        tokenB.mint(maker, type(uint224).max);
        tokenA.mint(taker, type(uint224).max);
        tokenB.mint(taker, type(uint224).max);

        maker.call{ value: 1 ether }("");
        taker.call{ value: 1 ether }("");

        vm.stopBroadcast();

        vm.broadcast(MAKER_PK);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.broadcast(TAKER_PK);
        tokenA.approve(address(swapVM), type(uint256).max);
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
