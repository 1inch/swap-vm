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
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @title WhitelistGas tests
contract WhitelistGas is Test, LimitOpcodesDebug {
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

    enum WhitelistType {
        Single,
        Multiple
    }

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) { }

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new LimitSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

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
    }

    function test_Whitelist_Single() public {
        ISwapVM.Order memory order = _buildOrder(_buildProgram(WhitelistType.Single, 1));
        bytes memory takerData = _buildTakerData();

        vm.prank(ALLOWED_TAKERS[0]);
        swapVM.quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);

        vm.prank(ALLOWED_TAKERS[1]);
        vm.expectRevert(Whitelist.WhitelistInvalidTaker.selector);
        swapVM.quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
    }

    function test_Whitelist_Multiple() public {
        bytes memory takerData = _buildTakerData();

        for (uint256 length; length < 26; ++length) {
            ISwapVM.Order memory order = _buildOrder(_buildProgram(WhitelistType.Multiple, length));

            for (uint256 i; i < length; ++i) {
                vm.prank(ALLOWED_TAKERS[i]);
                swapVM.quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
            }

            if (length < 25) {
                vm.prank(ALLOWED_TAKERS[length]);
                vm.expectRevert(Whitelist.WhitelistInvalidTaker.selector);
                swapVM.quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
            }

            vm.prank(address(0xaffacfed));
            vm.expectRevert(Whitelist.WhitelistInvalidTaker.selector);
            swapVM.quote(order, address(tokenA), address(tokenB), SWAP_AMOUNT, takerData);
        }
    }

    /// @dev staticBalances -> limitswap -> whitelist
    function _buildProgram(WhitelistType whitelistType, uint256 length) internal view returns (bytes memory) {
        address[] memory allowedTakers = new address[](length);
        for (uint256 i; i < length; ++i) allowedTakers[i] = ALLOWED_TAKERS[i];

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory code = bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([BALANCE_A, BALANCE_B]))),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        // console.logBytes(WhitelistArgsBuilder.buildWhitelistMultipleTakers(allowedTakers));
        if (whitelistType == WhitelistType.Single) {
            code = bytes.concat(code, p.build(_whitelistSingleTaker, WhitelistArgsBuilder.buildWhitelistSingleTaker(allowedTakers[0])));
        } else if (whitelistType == WhitelistType.Multiple) {
            code = bytes.concat(code, p.build(_whitelistMultipleTakers, WhitelistArgsBuilder.buildWhitelistMultipleTakers(allowedTakers)));
        }

        return code;
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
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
