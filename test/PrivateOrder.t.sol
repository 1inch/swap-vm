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

/// @title Whitelist tests
contract WhitelistTest is Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    LimitSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;

    uint256 constant BALANCE_A = 1000e18;
    uint256 constant BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    address ALLOWED_TAKER = 0x00000000000000eE000200000000000000fF0002;
    address COLLISION_TAKER = 0x00000000000000bAdbad00000000000000fF0002;
    address BAD_TAKER = 0x00000000000000eE000200000000000000BadBad;

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) { }

    function setUp() public {
        maker = vm.addr(makerPK);
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
    }

    function test_PrivateOrder() public {
        ISwapVM.Order memory order = _buildOrder(_buildProgram());
        bytes memory takerData = _buildTakerData();

        vm.prank(ALLOWED_TAKER);
        swapVM.quote(order, SWAP_AMOUNT, takerData);

        vm.prank(COLLISION_TAKER);
        swapVM.quote(order, SWAP_AMOUNT, takerData);

        vm.prank(BAD_TAKER);
        vm.expectRevert(Whitelist.WhitelistInvalidTaker.selector);
        swapVM.quote(order, SWAP_AMOUNT, takerData);
    }

    /// @dev whitelist -> staticBalances -> limitswap
    function _buildProgram() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory code = bytes.concat(
            p.build(_privateOrder, WhitelistArgsBuilder.buildPrivateOrder(ALLOWED_TAKER)),
            p.build(_staticBalancesXD, BalancesArgsBuilder.build([BALANCE_A, BALANCE_B])),
            p.build(_limitSwap1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );

        return code;
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
            isAToB: true,
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
