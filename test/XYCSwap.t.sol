// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder } from "../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { RoundingInvariants } from "./invariants/RoundingInvariants.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract XYCSwapTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockToken public tokenA;
    MockToken public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        tokenA = new MockToken("Token A", "TKA");
        tokenB = new MockToken("Token B", "TKB");

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
        Program memory program = ProgramBuilder.init(_opcodes());

        bytes memory bytecode;
        if (feeIn > 0) {
            bytecode = bytes.concat(
                program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
                program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(uint32(feeIn))),
                program.build(_xycSwapXD)
            );
        } else {
            bytecode = bytes.concat(
                program.build(_dynamicBalancesXD, BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
                program.build(_xycSwapXD)
            );
        }

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
            program: bytecode
        }));
    }

    function _signAndPack(ISwapVM.Order memory order, bool isExactIn, uint256 threshold) internal view returns (bytes memory) {
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
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        assertEq(amountOut, expectedOut, "Output should match x*y=k formula");
    }

    function test_XYCSwap_BasicSwap_WithFee() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;
        uint256 feeIn = 0.003e9; // 0.3%

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, feeIn);
        bytes memory takerData = _signAndPack(order, true, 0);

        uint256 amountIn = 10e18;
        uint256 amountInAfterFee = amountIn * (1e9 - feeIn) / 1e9;
        uint256 expectedOut = (amountInAfterFee * poolB) / (poolA + amountInAfterFee);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenA), address(tokenB), amountIn, takerData);

        assertEq(amountOut, expectedOut, "Output should account for fee");
    }

    function test_XYCSwap_MultipleSwaps_UpdatesState() public {
        uint256 poolA = 1000e18;
        uint256 poolB = 1000e18;

        ISwapVM.Order memory order = _makeOrder(poolA, poolB, 0);
        bytes memory takerData = _signAndPack(order, true, 0);

        // First swap
        vm.prank(taker);
        (, uint256 amountOut1,) = swapVM.swap(order, address(tokenA), address(tokenB), 10e18, takerData);

        // Second swap (state has changed)
        vm.prank(taker);
        (, uint256 amountOut2,) = swapVM.swap(order, address(tokenA), address(tokenB), 10e18, takerData);

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
        uint256 feeIn = 0.003e9; // 0.3%

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
        uint256 feeIn = 0.01e9; // 1%

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
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountOut) {
        vm.prank(taker);
        (, amountOut,) = _swapVM.swap(order, tokenIn, tokenOut, amount, takerData);
    }
}

