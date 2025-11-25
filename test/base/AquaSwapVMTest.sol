// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MockTaker } from "../mocks/MockTaker.sol";

import { SwapVM } from "../../src/SwapVM.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "../../src/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";

import { TestConstants } from "./TestConstants.sol";
import { AquaStrategyBuilders } from "./AquaStrategyBuilders.sol";

contract AquaSwapVMTest is TestConstants, AquaStrategyBuilders {
    struct SwapProgram {
        uint256 amount;
        MockTaker taker;
        TokenMock tokenA;
        TokenMock tokenB;
        bool zeroForOne;
        bool isExactIn;
    }

    AquaSwapVMRouter public swapVM;

    MockTaker public taker;
    MockTaker public taker2;

    address public protocolFeeRecipient;

    constructor() AquaStrategyBuilders(address(aqua)) {}

    function setUp() public override virtual {
        super.setUp();

        swapVM = new AquaSwapVMRouter(address(aqua), "SwapVM", "1.0.0");

        taker = new MockTaker(aqua, swapVM, address(this));
        taker2 = new MockTaker(aqua, swapVM, address(this));

        protocolFeeRecipient = vm.addr(0x8888);
    }

    // ===== HELPER FUNCTIONS =====
    function getTokenPair(SwapProgram memory swapProgram)
        internal
        pure
        returns (TokenMock tokenIn, TokenMock tokenOut)
    {
        return swapProgram.zeroForOne ?
            (swapProgram.tokenA, swapProgram.tokenB) :
            (swapProgram.tokenB, swapProgram.tokenA);
    }

    function getTokenAddresses(SwapProgram memory swapProgram)
        internal
        pure
        returns (address tokenIn, address tokenOut)
    {
        return swapProgram.zeroForOne ?
            (address(swapProgram.tokenA), address(swapProgram.tokenB)) :
            (address(swapProgram.tokenB), address(swapProgram.tokenA));
    }

    function getProtocolRecipientBalances() public view returns (uint256 balanceA, uint256 balanceB) {
        balanceA = tokenA.balanceOf(protocolFeeRecipient);
        balanceB = tokenB.balanceOf(protocolFeeRecipient);
    }

    function getAquaBalances(
        bytes32 strategyHash
    ) public view returns (uint256 balanceA, uint256 balanceB) {
        return aqua.safeBalances(maker, address(swapVM), strategyHash, address(tokenA), address(tokenB));
    }

    function getTakerBalances(
        MockTaker _taker
    ) public view returns (uint256 balanceA, uint256 balanceB) {
        balanceA = tokenA.balanceOf(address(_taker));
        balanceB = tokenB.balanceOf(address(_taker));
    }

    function mintTokenInToTaker(
        SwapProgram memory swapProgram
    ) public {
        mintTokenInToTaker(swapProgram, swapProgram.amount);
    }

    function mintTokenInToTaker(
        SwapProgram memory swapProgram,
        uint256 amount
    ) public {
        (TokenMock tokenIn, ) = getTokenPair(swapProgram);
        tokenIn.mint(address(swapProgram.taker), amount);
    }

    function mintTokenOutToMaker(
        SwapProgram memory swapProgram,
        uint256 amountOut
    ) public {
        (, TokenMock tokenOut) = getTokenPair(swapProgram);
        tokenOut.mint(maker, amountOut);
    }

    function takerData(address takerAddress, bool isExactIn) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddress,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "", // no minimum output
            to: address(0),
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

    function shipStrategy(
        ISwapVM.Order memory order,
        TokenMock tokenIn,
        TokenMock tokenOut,
        uint256 balanceIn,
        uint256 balanceOut
    ) public returns (bytes32) {
        return shipStrategy(
            swapVM,
            order,
            tokenIn,
            tokenOut,
            balanceIn,
            balanceOut
        );
    }

    function swap(
        SwapProgram memory swapProgram,
        ISwapVM.Order memory order
    ) public returns (uint256, uint256) {
        bytes memory sigAndTakerData = abi.encodePacked(takerData(address(swapProgram.taker), swapProgram.isExactIn));
        (address tokenIn, address tokenOut) = getTokenAddresses(swapProgram);

        return swapProgram.taker.swap(
            order,
            tokenIn,
            tokenOut,
            swapProgram.amount,
            sigAndTakerData
        );
    }

    function quote(
        SwapProgram memory swapProgram,
        ISwapVM.Order memory order
    ) public view returns (uint256, uint256) {
        (address tokenIn, address tokenOut) = getTokenAddresses(swapProgram);
        bytes memory sigAndTakerData = abi.encodePacked(takerData(address(swapProgram.taker), swapProgram.isExactIn));

        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order,
            tokenIn,
            tokenOut,
            swapProgram.amount,
            sigAndTakerData
        );

        return (amountIn, amountOut);
    }

    function tradeToZeroBalance(
        ISwapVM.Order memory order,
        TokenMock token
    ) public returns (uint256 amountIn, uint256 amountOut) {
        bytes32 orderHash = swapVM.hash(order);
        (uint256 aquaBalance,) = aqua.rawBalances(maker, address(swapVM), orderHash, address(token));

        SwapProgram memory swapProgram = SwapProgram({
            amount: aquaBalance,
            zeroForOne: tokenA == token ? false : true,
            taker: taker,
            isExactIn: false,
            tokenA: tokenA,
            tokenB: tokenB
        });

        (amountIn, amountOut) = quote(
            swapProgram,
            order
        );

        (TokenMock tokenIn, TokenMock tokenOut) = getTokenPair(swapProgram);

        tokenIn.mint(address(swapProgram.taker), amountIn);
        tokenOut.mint(maker, aquaBalance);

        return swap(
            swapProgram,
            order
        );
    }

    function price(
        ISwapVM.Order memory order,
        SwapProgram memory swapProgram
    ) internal view returns (uint256, uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut) = quote(
            swapProgram,
            order
        );
        return ((amountOut * ONE) / amountIn, amountIn, amountOut);
    }
}
