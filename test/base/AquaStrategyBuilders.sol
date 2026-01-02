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
import { AquaSwapVMRouter } from "../../src/routers/AquaSwapVMRouter.sol";
import { AquaOpcodesDebug } from "../../src/opcodes/AquaOpcodesDebug.sol";

import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { XYCConcentrateExperimental } from "../../src/instructions/XYCConcentrateExperimental.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { FeeExperimental, FeeArgsBuilderExperimental } from "../../src/instructions/FeeExperimental.sol";
import { Controls } from "../../src/instructions/Controls.sol";

import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { TestConstants } from "./TestConstants.sol";

/**
 * @title StrategyBuilders
 * @notice Abstract contract that provides helper methods for building various swap strategies
 * @dev Inherits from Test and OpcodesDebug to have access to vm and _opcodes() function
 */
abstract contract AquaStrategyBuilders is TestConstants, Test, AquaOpcodesDebug {
    using ProgramBuilder for Program;

    enum SwapType {
        XYC,
        CONCENTRATE_GROW_PRICE_RANGE,
        CONCENTRATE_GROW_LIQUIDITY
    }

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        uint256 priceMin;
        uint256 priceMax;
        uint32 protocolFeeBps;
        uint32 feeInBps;
        uint32 feeOutBps;
        uint32 progressiveFeeBps;
        address protocolFeeRecipient;
        SwapType swapType;
    }

    Aqua public immutable aqua = new Aqua();

    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;

    constructor(address _aqua) AquaOpcodesDebug(_aqua) {}

    function setUp() public virtual {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy mock tokens
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
    }

    function buildProgram(MakerSetup memory setup) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory concentrateProgram = "";

        if(setup.swapType == SwapType.CONCENTRATE_GROW_LIQUIDITY ||
            setup.swapType == SwapType.CONCENTRATE_GROW_PRICE_RANGE) {
            (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
                setup.balanceA,
                setup.balanceB,
                setup.balanceB * TestConstants.ONE / setup.balanceA,
                setup.priceMin,
                setup.priceMax
            );
            concentrateProgram = p.build(
                setup.swapType == SwapType.CONCENTRATE_GROW_LIQUIDITY ?
                    XYCConcentrate._xycConcentrateGrowLiquidity2D :
                    XYCConcentrateExperimental._xycConcentrateGrowPriceRange2D,
                XYCConcentrateArgsBuilder.build2D(
                    address(tokenA),
                    address(tokenB),
                    deltaA,
                    deltaB,
                    liquidity
                )
            );
        }

        return bytes.concat(
            setup.feeInBps > 0 ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(setup.feeInBps)) : bytes(""),
            setup.feeOutBps > 0 ? p.build(FeeExperimental._flatFeeAmountOutXD, FeeArgsBuilder.buildFlatFee(setup.feeOutBps)) : bytes(""),
            setup.protocolFeeBps > 0 ? p.build(FeeExperimental._aquaProtocolFeeAmountOutXD, FeeArgsBuilder.buildProtocolFee(setup.protocolFeeBps, setup.protocolFeeRecipient)) : bytes(""),
            setup.progressiveFeeBps > 0 ? p.build(FeeExperimental._progressiveFeeInXD, FeeArgsBuilderExperimental.buildProgressiveFee(setup.progressiveFeeBps)) : bytes(""),
            concentrateProgram,
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint())) // ensure unique order hash
        );
    }

    function createStrategy(
        bytes memory programBytes
    ) public view returns (ISwapVM.Order memory order) {
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

    function createStrategy(
        MakerSetup memory setup
    ) public view returns (ISwapVM.Order memory) {
        return createStrategy(buildProgram(setup));
    }

    function shipStrategy(
        AquaSwapVMRouter swapVM,
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
