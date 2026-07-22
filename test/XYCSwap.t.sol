// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { StaticBalances, DynamicBalances } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { FeeFlatIn, FeeFlatOut } from "../src/instructions/FeeFlat.sol";

import { RoundingInvariants } from "./invariants/RoundingInvariants.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract XYCSwapTest is Test, OpcodesDebug {
    constructor() {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new MockToken("Token I", "TKI");
        tokenB = new MockToken("Token J", "TKJ");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1000000e18);
        tokenB.mint(maker, 1000000e18);
        tokenA.mint(taker, 1000000e18);
        tokenB.mint(taker, 1000000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ========================================
    // HELPER FUNCTIONS
    // ========================================

    function _makeOrder(uint256 balanceA, uint256 balanceB, uint256 feeIn) internal view returns (ISwapVM.Order memory) {
        bytes memory bytecode;
        if (feeIn > 0) {
            bytecode = bytes.concat(
                DynamicBalances.build(balanceA, balanceB),
                FeeFlatIn.build(uint24(feeIn)),
                XYCSwap.build()
            );
        } else {
            bytecode = bytes.concat(
                DynamicBalances.build(balanceA, balanceB),
                XYCSwap.build()
            );
        }

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
            program: bytecode
        }));
    }

    function _signAndPack(ISwapVM.Order memory order, bool isExactIn, uint256 threshold) internal view returns (bytes memory) {
        return _signAndPack(order, isExactIn, threshold, true);
    }

    function _signAndPack(ISwapVM.Order memory order, bool isExactIn, uint256 threshold, bool isAToB) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        return abi.encodePacked(TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            threshold: thresholdData,
            to: taker,
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
            signature: signature
        })));
    }

    // ========================================
    // BASIC SWAP TESTS
    // ========================================

    function test_XYCSwap_BasicSwap_NoFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, 0);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 10e18;
        uint256 expectedOut = (amountIn * poolB) / (poolA + amountIn);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, takerData);

        assertEq(amountOut, expectedOut, "Output should match x*y=k formula");
    }

    function test_XYCSwap_BasicSwap_WithFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 feeIn = 0.003e7; // 0.3%

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, feeIn);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 10e18;
        uint256 amountInAfterFee = amountIn * (1e7 - feeIn) / 1e7;
        uint256 expectedOut = (amountInAfterFee * poolB) / (poolA + amountInAfterFee);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, takerData);

        assertEq(amountOut, expectedOut, "Output should account for fee");
    }

    function test_XYCSwap_MultipleSwaps_UpdatesState() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, 0);
        bytes memory takerData = _signAndPack(order, true, 0);

        // First swap
        vm.prank(taker);
        (, uint256 amountOut1,) = swapVM.swap(order, 10e18, takerData);

        // Second swap (state has changed)
        vm.prank(taker);
        (, uint256 amountOut2,) = swapVM.swap(order, 10e18, takerData);

        assertLt(amountOut2, amountOut1, "Second swap should get worse rate");
    }

    // ========================================
    // ROUNDING INVARIANT TESTS
    // ========================================

    function test_XYCSwap_RoundingInvariants_NoFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, 0);
        bytes memory takerData = _signAndPack(order, true, 0);

        RoundingInvariants.assertRoundingInvariants(
            vm,
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            takerData,
            _executeSwap
        );
    }

    function test_XYCSwap_RoundingInvariants_WithFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 feeIn = 0.003e7; // 0.3%

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, feeIn);
        bytes memory takerData = _signAndPack(order, true, 0);

        RoundingInvariants.assertRoundingInvariants(
            vm,
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            takerData,
            _executeSwap
        );
    }

    function test_XYCSwap_RoundingInvariants_HighFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 feeIn = 0.01e7; // 1%

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, feeIn);
        bytes memory takerData = _signAndPack(order, true, 0);

        RoundingInvariants.assertRoundingInvariants(
            vm,
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            takerData,
            _executeSwap
        );
    }

    // Helper function to execute swaps for invariant testing
    // Direction (isAToB) is derived per-call from tokenIn/tokenOut so round-trip
    // invariants can swap both ways; the passed takerData is ignored in favor of
    // a freshly packed one carrying the correct direction.
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory /* takerData */
    ) internal returns (uint256 amountOut) {
        bytes memory takerData = _signAndPack(order, true, 0, tokenIn < tokenOut);
        vm.prank(taker);
        (, amountOut,) = _swapVM.swap(order, amount, takerData);
    }
}

