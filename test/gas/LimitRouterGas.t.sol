// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../../src/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { StaticBalances } from "../../src/instructions/Balances.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { Salt, Deadline } from "../../src/instructions/Controls.sol";
import { InvalidateTokenIn, InvalidateBit } from "../../src/instructions/Invalidators.sol";

/// @title LimitRouterGas
/// @notice Limit-order gas benchmarks.
contract LimitRouterGas is Test {
    LimitSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant LIMIT_BALANCE_A = 1000e18;
    uint256 constant LIMIT_BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new LimitSwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

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

    function test_gas_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwap(true);
        snapshotQuote("LimitRouterQuote", "LimitSwap_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwap(true);
        snapshotSwap("LimitRouterSwap", "LimitSwap_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwap(false);
        snapshotQuote("LimitRouterQuote", "LimitSwap_exactOut", order, takerData);
    }

    function test_gas_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwap(false);
        snapshotSwap("LimitRouterSwap", "LimitSwap_exactOut", order, takerData);
    }

    function test_gas_Deadline_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDeadlineLimitSwap(true);
        snapshotQuote("LimitRouterQuote", "Deadline_LimitSwap_exactIn", order, takerData);
    }

    function test_gas_Deadline_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDeadlineLimitSwap(true);
        snapshotSwap("LimitRouterSwap", "Deadline_LimitSwap_exactIn", order, takerData);
    }

    function test_gas_Deadline_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDeadlineLimitSwap(false);
        snapshotQuote("LimitRouterQuote", "Deadline_LimitSwap_exactOut", order, takerData);
    }

    function test_gas_Deadline_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDeadlineLimitSwap(false);
        snapshotSwap("LimitRouterSwap", "Deadline_LimitSwap_exactOut", order, takerData);
    }

    function test_gas_Salt_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programSaltLimitSwap(true);
        snapshotQuote("LimitRouterQuote", "Salt_LimitSwap_exactIn", order, takerData);
    }

    function test_gas_Salt_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programSaltLimitSwap(true);
        snapshotSwap("LimitRouterSwap", "Salt_LimitSwap_exactIn", order, takerData);
    }

    function test_gas_Salt_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programSaltLimitSwap(false);
        snapshotQuote("LimitRouterQuote", "Salt_LimitSwap_exactOut", order, takerData);
    }

    function test_gas_Salt_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programSaltLimitSwap(false);
        snapshotSwap("LimitRouterSwap", "Salt_LimitSwap_exactOut", order, takerData);
    }

    function test_gas_InvalidateBit_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programInvalidateBitLimitSwap(true);
        snapshotQuote("LimitRouterQuote", "InvalidateBit_LimitSwap_exactIn", order, takerData);
    }

    function test_gas_InvalidateBit_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programInvalidateBitLimitSwap(true);
        snapshotSwap("LimitRouterSwap", "InvalidateBit_LimitSwap_exactIn", order, takerData);
    }

    function test_gas_InvalidateBit_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programInvalidateBitLimitSwap(false);
        snapshotQuote("LimitRouterQuote", "InvalidateBit_LimitSwap_exactOut", order, takerData);
    }

    function test_gas_InvalidateBit_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programInvalidateBitLimitSwap(false);
        snapshotSwap("LimitRouterSwap", "InvalidateBit_LimitSwap_exactOut", order, takerData);
    }

    function test_gas_LimitSwap_InvalidateTokenIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwapInvalidateTokenIn(true);
        snapshotQuote("LimitRouterQuote", "LimitSwap_InvalidateTokenIn_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_InvalidateTokenIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwapInvalidateTokenIn(true);
        snapshotSwap("LimitRouterSwap", "LimitSwap_InvalidateTokenIn_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_InvalidateTokenIn_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwapInvalidateTokenIn(false);
        snapshotQuote("LimitRouterQuote", "LimitSwap_InvalidateTokenIn_exactOut", order, takerData);
    }

    function test_gas_LimitSwap_InvalidateTokenIn_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programLimitSwapInvalidateTokenIn(false);
        snapshotSwap("LimitRouterSwap", "LimitSwap_InvalidateTokenIn_exactOut", order, takerData);
    }

    function test_gas_FullLimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullLimitSwap(true);
        snapshotQuote("LimitRouterQuote", "FullLimitSwap_exactIn", order, takerData);
    }

    function test_gas_FullLimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullLimitSwap(true);
        snapshotSwap("LimitRouterSwap", "FullLimitSwap_exactIn", order, takerData);
    }

    function test_gas_FullLimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullLimitSwap(false);
        snapshotQuote("LimitRouterQuote", "FullLimitSwap_exactOut", order, takerData);
    }

    function test_gas_FullLimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullLimitSwap(false);
        snapshotSwap("LimitRouterSwap", "FullLimitSwap_exactOut", order, takerData);
    }

    function snapshotQuote(
        string memory group,
        string memory name,
        ISwapVM.Order memory order,
        bytes memory takerData
    ) internal {
        swapVM.asView().quote(order, SWAP_AMOUNT, takerData);
        uint256 gasUsed = uint256(vm.lastCallGas().gasTotalUsed);
        vm.snapshotValue(
            group,
            name,
            gasUsed + calldataGas(abi.encodeCall(ISwapVM.quote, (order, SWAP_AMOUNT, takerData)))
        );
    }

    function snapshotSwap(
        string memory group,
        string memory name,
        ISwapVM.Order memory order,
        bytes memory takerData
    ) internal {
        swapVM.swap(order, SWAP_AMOUNT, takerData);
        uint256 gasUsed = uint256(vm.lastCallGas().gasTotalUsed);
        vm.snapshotValue(
            group,
            name,
            gasUsed + calldataGas(abi.encodeCall(ISwapVM.swap, (order, SWAP_AMOUNT, takerData)))
        );
    }

    function calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function programLimitSwap(bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            bytes.concat(StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B), LimitSwap.build(address(tokenA), address(tokenB))),
            isExactIn
        );
    }

    function programDeadlineLimitSwap(bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            bytes.concat(
                Deadline.build(uint40(block.timestamp + 3600)),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function programSaltLimitSwap(bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            bytes.concat(
                Salt.build(12345678),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function programInvalidateBitLimitSwap(bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            bytes.concat(
                InvalidateBit.build(42),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function programLimitSwapInvalidateTokenIn(bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            bytes.concat(
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB)),
                InvalidateTokenIn.build()
            ),
            isExactIn
        );
    }

    function programFullLimitSwap(bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            bytes.concat(
                Deadline.build(uint40(block.timestamp + 3600)),
                Salt.build(99999),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB)),
                InvalidateTokenIn.build()
            ),
            isExactIn
        );
    }

    function buildOrder(bytes memory program, bool isExactIn) internal view returns (ISwapVM.Order memory, bytes memory) {
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

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);

        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
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
            signature: abi.encodePacked(r, s, v)
        }));

        return (order, abi.encodePacked(takerData));
    }
}
