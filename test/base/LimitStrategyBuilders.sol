// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVM } from "../../src/SwapVM.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";

import { LimitOpcodesDebug } from "../../src/opcodes/LimitOpcodesDebug.sol";

import { Balances, BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { DutchAuction, DutchAuctionArgsBuilder } from "../../src/instructions/DutchAuction.sol";
import { Fee, FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { Controls } from "../../src/instructions/Controls.sol";

import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { TestConstants } from "./TestConstants.sol";

abstract contract LimitStrategyBuilders is TestConstants, Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    enum SwapType {
        LIMIT,
        LIMIT_DUTCH
    }

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint32 protocolFeeBps;
        uint32 feeInBps;
        address protocolFeeRecipient;
        SwapType swapType;
    }

    Aqua public immutable aqua = new Aqua();

    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;

    constructor(address _aqua) LimitOpcodesDebug(_aqua) {}

    function setUp() public virtual {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
    }

    function buildProgram(MakerSetup memory setup) internal view virtual returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        address tokenIn = address(tokenA);
        address tokenOut = address(tokenB);
        uint256 balIn = setup.balanceA;
        uint256 balOut = setup.balanceB;

        bytes memory dutchInstruction = "";
        if (setup.swapType == SwapType.LIMIT_DUTCH) {
            dutchInstruction = p.build(
                DutchAuction._dutchAuctionBalanceIn1D,
                DutchAuctionArgsBuilder.build(uint40(block.timestamp), 3600, uint64(0.5e18))
            );
        }

        return bytes.concat(
            setup.protocolFeeBps > 0
                ? p.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(setup.protocolFeeBps, setup.protocolFeeRecipient))
                : bytes(""),
            setup.feeInBps > 0
                ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(setup.feeInBps))
                : bytes(""),
            p.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(dynamic([tokenIn, tokenOut]), dynamic([balIn, balOut]))),
            dutchInstruction,
            p.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut)),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    function createStrategy(bytes memory programBytes) public view returns (ISwapVM.Order memory order) {
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
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
            program: programBytes
        }));
    }

    function createStrategy(MakerSetup memory setup) public view returns (ISwapVM.Order memory) {
        return createStrategy(buildProgram(setup));
    }

    function shipStrategy(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        TokenMock tokenIn,
        TokenMock tokenOut,
        uint256 balanceIn,
        uint256 balanceOut
    ) public returns (bytes32) {
        bytes32 orderHash = swapVM.hash(order);

        vm.prank(maker);
        tokenIn.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenOut.approve(address(aqua), type(uint256).max);

        bytes memory strategy = abi.encode(order);

        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            strategy,
            dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([balanceIn, balanceOut])
        );
        vm.assume(strategyHash == orderHash);

        return strategyHash;
    }
}
