// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../src/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { Context } from "../src/libs/VM.sol";
import { Opcodes } from "../src/opcodes/Opcodes.sol";
import { LimitOpcodesDebug } from "../src/opcodes/LimitOpcodesDebug.sol";
import { Whitelist, WhitelistArgsBuilder } from "../src/instructions/Whitelist.sol";
import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { Jump } from "../src/instructions/Controls.sol";

/// @title Whitelist tests
contract WhitelistTest is Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    LimitSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant BALANCE_A = 1000e18;
    uint256 constant BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    address[25] ALLOWED_TAKERS;
    uint40 START;
    uint16[20] DURATIONS;

    enum WhitelistType {
        Coequal,
        Sequential
    }

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) { }

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new LimitSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        ALLOWED_TAKERS[ 0] = address(0x00000000000000eE000200000000000000fF0002);
        ALLOWED_TAKERS[ 1] = address(0x00000000000000Ee000100000000000000ff0001);
        ALLOWED_TAKERS[ 2] = address(0x00000000000000eE000300000000000000fF0003);
        ALLOWED_TAKERS[ 3] = address(0x00000000000000EE000a00000000000000FF000a);
        ALLOWED_TAKERS[ 4] = address(0x00000000000000eE000b00000000000000ff000b);
        ALLOWED_TAKERS[ 5] = address(0x00000000000000eE000D00000000000000Ff000d);
        ALLOWED_TAKERS[ 6] = address(0x00000000000000EE000C00000000000000FF000c);
        ALLOWED_TAKERS[ 7] = address(0x00000000000000eE000F00000000000000Ff000f);
        ALLOWED_TAKERS[ 8] = address(0x00000000000000EE000e00000000000000fF000e);
        ALLOWED_TAKERS[ 9] = address(0x00000000000000eE001000000000000000Ff0010);
        ALLOWED_TAKERS[10] = address(0x00000000000000Ee001100000000000000FF0011);
        ALLOWED_TAKERS[11] = address(0x00000000000000ee001200000000000000ff0012);
        ALLOWED_TAKERS[12] = address(0x00000000000000ee001300000000000000fF0013);
        ALLOWED_TAKERS[13] = address(0x00000000000000ee001400000000000000fF0014);
        ALLOWED_TAKERS[14] = address(0x00000000000000eE001500000000000000ff0015);
        ALLOWED_TAKERS[15] = address(0x00000000000000eE000400000000000000fF0004);
        ALLOWED_TAKERS[16] = address(0x00000000000000EE000500000000000000fF0005);
        ALLOWED_TAKERS[17] = address(0x00000000000000EE000600000000000000ff0006);
        ALLOWED_TAKERS[18] = address(0x00000000000000Ee000700000000000000FF0007);
        ALLOWED_TAKERS[19] = address(0x00000000000000Ee000800000000000000ff0008);
        ALLOWED_TAKERS[20] = address(0x00000000000000ee000900000000000000Ff0009);
        ALLOWED_TAKERS[21] = address(0x00000000000000eE001600000000000000fF0016);
        ALLOWED_TAKERS[22] = address(0x00000000000000ee001700000000000000FF0017);
        ALLOWED_TAKERS[23] = address(0x00000000000000EE001800000000000000ff0018);
        ALLOWED_TAKERS[24] = address(0x00000000000000ee001900000000000000Ff0019);

        START = 1700000000;
        DURATIONS[ 0] = 100;
        DURATIONS[ 1] = 200;
        DURATIONS[ 2] = 300;
        DURATIONS[ 3] = 150;
        DURATIONS[ 4] = 120;
        DURATIONS[ 5] = 200;
        DURATIONS[ 6] = 300;
        DURATIONS[ 7] = 150;
        DURATIONS[ 8] = 130;
        DURATIONS[ 9] = 0;
        DURATIONS[10] = 120;
        DURATIONS[11] = 300;
        DURATIONS[12] = 150;
        DURATIONS[13] = 100;
        DURATIONS[14] = 200;
        DURATIONS[15] = 300;
        DURATIONS[16] = 150;
        DURATIONS[17] = 130;
        DURATIONS[18] = 140;
        DURATIONS[19] = 120;
    }

    function test_Whitelist_Coequal() public {
        bytes memory takerData = _buildTakerData();

        for (uint256 length = 1; length <= 25; ++length) {
            ISwapVM.Order memory order = _buildOrder(_buildProgram(WhitelistType.Coequal, length));

            vm.prank(address(0xaffacfed));
            (, uint256 outF,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
            vm.prank(ALLOWED_TAKERS[0]);
            (, uint256 outT,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
            assertGt(outT, outF);

            // Every listed taker is routed to branchT
            for (uint256 i; i < length; ++i) {
                vm.prank(ALLOWED_TAKERS[i]);
                (, uint256 out,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
                assertEq(out, outT);
            }

            // The next, unlisted entry falls through to branchF
            if (length < 25) {
                vm.prank(ALLOWED_TAKERS[length]);
                (, uint256 out,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
                assertEq(out, outF);
            }
        }
    }

    function test_Whitelist_Coequal_GasBenchmark() public {
        // Warmup account
        address(swapVM).staticcall("");

        for (uint256 length = 1; length <= 25; ++length) {
            ISwapVM.Order memory order = _buildOrder(_buildProgram(WhitelistType.Coequal, length));
            bytes memory takerData = _buildTakerData();

            uint256 usage;
            uint256 worst;

            for (uint256 i; i < length; ++i) {
                vm.prank(ALLOWED_TAKERS[i]);
                uint256 gas = gasleft();
                swapVM.quote(order, SWAP_AMOUNT, takerData);
                uint256 temp = gas - gasleft();
                usage += temp;
                if (worst < temp) worst = temp;
            }

            console.log(usage / length, worst, length);
        }
    }

    function test_Whitelist_Sequential() public {
        bytes memory takerData = _buildTakerData();

        for (uint256 length = 1; length <= 20; ++length) {
            ISwapVM.Order memory order = _buildOrder(_buildProgram(WhitelistType.Sequential, length));

            uint256 ts = START;

            uint256 outF = SWAP_AMOUNT * BALANCE_A / BALANCE_B;
            uint256 outT = 2 * SWAP_AMOUNT * BALANCE_A / BALANCE_B;
            assertGt(outT, outF);

            for (uint256 i; i < length; ++i) {
                {
                    // Taker not listed yet
                    vm.warp(ts - 1);
                    vm.prank(ALLOWED_TAKERS[i]);
                    vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
                    swapVM.quote(order, SWAP_AMOUNT, takerData);
                }
                {
                    // Every listed taker is routed to branchT
                    vm.warp(ts);
                    vm.prank(ALLOWED_TAKERS[i]);
                    (, uint256 out,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
                    assertEq(out, outT);
                }

                ts += DURATIONS[i];
            }

            if (length < 20 && DURATIONS[length - 1] != 0) {
                // The next, unlisted entry still reverts
                vm.prank(ALLOWED_TAKERS[length]);
                vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
                swapVM.quote(order, SWAP_AMOUNT, takerData);

                // Aliens are not allowed
                vm.prank(address(0xaffacfed));
                vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
                swapVM.quote(order, SWAP_AMOUNT, takerData);
            } else if (length == 20) {
                // During the last duration aliens are still not allowed
                vm.prank(address(0xaffacfed));
                vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
                swapVM.quote(order, SWAP_AMOUNT, takerData);

                // All durations passed, any unlisted pass through branchF
                vm.warp(ts);
                {
                    vm.prank(address(0xaffacfed));
                    (, uint256 out,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
                    assertEq(out, outF);
                }
                {
                    vm.prank(ALLOWED_TAKERS[length - 1]);
                    (, uint256 out,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
                    assertEq(out, outT);
                }
                {
                    vm.prank(ALLOWED_TAKERS[0]);
                    (, uint256 out,) = swapVM.quote(order, SWAP_AMOUNT, takerData);
                    assertEq(out, outT);
                }
            }
        }
    }

    function test_Whitelist_Sequential_GasBenchmark() public {
        // Warmup account
        address(swapVM).staticcall("");
        vm.warp(type(uint40).max);

        for (uint256 length = 1; length <= 20; ++length) {
            ISwapVM.Order memory order = _buildOrder(_buildProgram(WhitelistType.Sequential, length));
            bytes memory takerData = _buildTakerData();

            uint256 usage;
            uint256 worst;

            for (uint256 i; i < length; ++i) {
                vm.prank(ALLOWED_TAKERS[i]);
                uint256 gas = gasleft();
                swapVM.quote(order, SWAP_AMOUNT, takerData);
                uint256 temp = gas - gasleft();
                usage += temp;
                if (worst < temp) worst = temp;
            }

            console.log(usage / length, worst, length);
        }
    }

    /// @dev condition -> staticBalances A or B -> limitswap
    function _buildProgram(WhitelistType whitelistType, uint256 length) internal view returns (bytes memory) {
        Program p;

        uint16 conditionLength;
        uint16 branchFLength = 2 + 64 + 2 + 2;
        uint16 branchTLength = 2 + 64;
        uint16 finLength = 2 + 1;

        bytes memory condition;
        if (whitelistType == WhitelistType.Coequal) {
            address[] memory allowedTakers = new address[](length);
            for (uint256 i; i < length; ++i) allowedTakers[i] = ALLOWED_TAKERS[i];

            conditionLength = uint16(2 + 2 + length * 10);
            condition = p.build(Opcode.WhitelistCoequal, WhitelistArgsBuilder.buildWhitelistCoequal(conditionLength + branchFLength, allowedTakers));
            assertEq(conditionLength, condition.length);
        } else if (whitelistType == WhitelistType.Sequential) {
            address[] memory allowedTakers = new address[](length);
            for (uint256 i; i < length; ++i) allowedTakers[i] = ALLOWED_TAKERS[i];
            uint16[] memory durations = new uint16[](length);
            for (uint256 i; i < length; ++i) durations[i] = DURATIONS[i];

            conditionLength = uint16(7 + 2 + length * 12);
            condition = p.build(Opcode.WhitelistSequential, WhitelistArgsBuilder.buildWhitelistSequential(conditionLength + branchFLength, START, allowedTakers, durations));
            assertEq(conditionLength, condition.length);
        }

        bytes memory branchF = bytes.concat(
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([BALANCE_A, BALANCE_B])),
            Jump.build(conditionLength + branchFLength + branchTLength)
        );
        assertEq(branchFLength, branchF.length);
        bytes memory branchT = p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([BALANCE_A * 2, BALANCE_B]));
        assertEq(branchTLength, branchT.length);

        bytes memory fin = p.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)));
        assertEq(finLength, fin.length);

        return bytes.concat(condition, branchF, branchT, fin);
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
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

    function _buildTakerData() private view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            isAToB: false,
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
