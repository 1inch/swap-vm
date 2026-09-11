// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";

import { SwapVMRouter, TraitsHelper, DeployCode } from "../helpers/SwapVMTestSetup.sol";

import { XYCConcentrateSwap } from "../../../contracts/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../../../contracts/instructions/XYCSwap.sol";
import { Salt } from "../../../contracts/instructions/Controls.sol";
import { FeeFlatIn } from "../../../contracts/instructions/FeeFlat.sol";
import { FeeBuilders } from "../utils/FeeBuilders.sol";


import { dynamic } from "../utils/Dynamic.sol";

import { TestConstants } from "./TestConstants.sol";

/**
 * @title StrategyBuilders
 * @notice Abstract contract that provides helper methods for building various swap strategies
 * @dev Inherits from Test to have access to vm
 */
abstract contract AquaStrategyBuilders is TestConstants, Test {
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
        uint24 protocolFeeBps;
        uint24 feeInBps;
        address protocolFeeRecipient;
        SwapType swapType;
    }

    Aqua public immutable aqua = new Aqua();

    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    TraitsHelper internal orders;

    function setUp() public virtual {
        orders = DeployCode.TraitsHelper();
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy mock tokens
        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    function buildProgram(MakerSetup memory setup) internal view virtual returns (bytes memory) {
        bytes memory concentrateProgram = "";

        if(setup.swapType == SwapType.CONCENTRATE_GROW_LIQUIDITY ||
            setup.swapType == SwapType.CONCENTRATE_GROW_PRICE_RANGE) {
            // In the new API, use sqrt price bounds directly
            // priceMin/priceMax are in 1e18 format; sqrtP = sqrt(price * 1e18)
            uint256 sqrtPmin = Math.sqrt(setup.priceMin * 1e18);
            uint256 sqrtPmax = Math.sqrt(setup.priceMax * 1e18);
            concentrateProgram = XYCConcentrateSwap.build(sqrtPmin, sqrtPmax);
        }

        bytes memory swapProgram = concentrateProgram.length > 0
            ? concentrateProgram
            : XYCSwap.build();

        return bytes.concat(
            setup.protocolFeeBps > 0 ? FeeBuilders.protocolFeeIn(setup.protocolFeeBps, setup.protocolFeeRecipient) : bytes(""),
            setup.feeInBps > 0 ? FeeFlatIn.build(setup.feeInBps) : bytes(""),
            swapProgram,
            Salt.build(abi.encodePacked(vm.randomUint()))
        );
    }

    function createStrategy(
        bytes memory programBytes
    ) public view returns (ISwapVM.Order memory order) {
        order = orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            program: programBytes
        }));
    }

    function createStrategy(
        MakerSetup memory setup
    ) public view returns (ISwapVM.Order memory) {
        return createStrategy(buildProgram(setup));
    }

    function shipStrategy(
        SwapVMRouter swapVM,
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
