// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IPermit2 } from "@1inch/solidity-utils/contracts/interfaces/IPermit2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../../contracts/SwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib, TakerTraits } from "../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances, DynamicBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { InvalidateTokenOut, InvalidateTokenIn, InvalidateBit } from "../../contracts/instructions/Invalidators.sol";
import { Salt } from "../../contracts/instructions/Controls.sol";
import { Permit2TestLib } from "./helpers/Permit2TestLib.sol";

contract SwapVMTest is Test, OpcodesDebug {
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    struct MakerSetup {
        uint256 balanceA;
        uint256 balanceB;
        address tokenIn;
        address tokenOut;
        bool usePermit2;
        bool useInvalidator;
        uint256 salt;
    }

    struct TakerSetup {
        bool isExactIn;
        uint256 threshold;
        bool isFirstTransferFromTaker;
    }

    struct SwapResult {
        uint256 amountIn;
        uint256 amountOut;
        bytes32 orderHash;
    }

    struct BalanceSnapshot {
        uint256 takerTokenA;
        uint256 takerTokenB;
    }

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy custom SwapVM router with Invalidators
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _createOrder(MakerSetup memory setup) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        bytes memory programBytes = bytes.concat(
            StaticBalances.build(setup.balanceA, setup.balanceB),
            LimitSwap.build(setup.tokenIn, setup.tokenOut),
            setup.useInvalidator ? InvalidateTokenOut.build() : bytes(""),
            setup.salt != 0 ? Salt.build(uint64(setup.salt)) : bytes("")
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: setup.usePermit2,
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

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildTakerData(uint256 threshold, bytes memory signature) internal view returns (bytes memory) {
        return _buildTakerData(threshold, signature, false);
    }

    function _buildTakerData(uint256 threshold, bytes memory signature, bool usePermit2) internal view returns (bytes memory) {
        return _buildTakerData(threshold, signature, usePermit2, true, true);
    }

    function _buildTakerData(
        uint256 threshold,
        bytes memory signature,
        bool usePermit2,
        bool isExactIn,
        bool isFirstTransferFromTaker
    ) internal view returns (bytes memory) {
        // Build taker data step by step to avoid stack too deep
        TakerTraitsLib.Args memory args;
        args.taker = taker;
        args.isExactIn = isExactIn;
        args.usePermit2 = usePermit2;
        args.isAToB = false;
        args.isFirstTransferFromTaker = isFirstTransferFromTaker;
        args.threshold = threshold > 0 ? abi.encodePacked(threshold) : bytes("");
        args.signature = signature;

        // All other fields remain default (false/0/empty)
        return TakerTraitsLib.build(args);
    }

    /// @notice Sets up expectation that SwapVM contract will emit Swapped event with these parameters
    /// @dev The emit here is NOT broadcasting - it's Foundry's syntax to specify expected event values.
    ///      Test fails if contract doesn't emit matching event on next call.
    function _expectSwappedEvent(
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 expectedAmountIn,
        uint256 expectedAmountOut
    ) internal {
        bytes32 orderHash = swapVM.hash(order);
        vm.expectEmit(true, true, true, true, address(swapVM));
        // Specify expected event parameters (Foundry will verify contract emits this)
        emit SwapVM.Swapped(
            orderHash,
            maker,
            taker,
            tokenIn,
            tokenOut,
            expectedAmountIn,
            expectedAmountOut
        );
    }

    function _executeSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bytes memory takerData
    ) internal returns (SwapResult memory) {
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut, bytes32 orderHash) = swapVM.swap(
            order,
            amount,
            takerData
        );
        return SwapResult(amountIn, amountOut, orderHash);
    }

    function _executeSwapWithEventCheck(
        ISwapVM.Order memory order,
        uint256 amount,
        bytes memory takerData,
        uint256 expectedAmountIn,
        uint256 expectedAmountOut
    ) internal returns (SwapResult memory) {
        _expectSwappedEvent(order, address(tokenB), address(tokenA), expectedAmountIn, expectedAmountOut);
        return _executeSwap(order, amount, takerData);
    }

    function _getBalances() internal view returns (BalanceSnapshot memory) {
        return BalanceSnapshot({
            takerTokenA: tokenA.balanceOf(taker),
            takerTokenB: tokenB.balanceOf(taker)
        });
    }

    function _verifySwap(
        SwapResult memory result,
        BalanceSnapshot memory before,
        uint256 expectedIn,
        uint256 expectedOut,
        string memory message
    ) internal view {
        BalanceSnapshot memory afterSwap = _getBalances();

        assertEq(result.amountIn, expectedIn, string(abi.encodePacked(message, ": incorrect amountIn")));
        assertEq(result.amountOut, expectedOut, string(abi.encodePacked(message, ": incorrect amountOut")));
        assertEq(afterSwap.takerTokenA - before.takerTokenA, expectedOut, string(abi.encodePacked(message, ": incorrect TokenA received")));
        assertEq(before.takerTokenB - afterSwap.takerTokenB, expectedIn, string(abi.encodePacked(message, ": incorrect TokenB spent")));
    }

    function _verifySwapWithOrderHash(
        SwapResult memory result,
        BalanceSnapshot memory before,
        uint256 expectedIn,
        uint256 expectedOut,
        bytes32 expectedOrderHash,
        string memory message
    ) internal view {
        _verifySwap(result, before, expectedIn, expectedOut, message);
        assertEq(result.orderHash, expectedOrderHash, string(abi.encodePacked(message, ": incorrect orderHash")));
    }


    function test_LimitSwapWithTokenOutInvalidator() public {
        // === Setup ===
        // Maker offers to sell 100 TokenA for 200 TokenB (rate: 2 TokenB per 1 TokenA)
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: true,
            salt: 0x1235
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature);
        bytes32 expectedOrderHash = swapVM.hash(order);

        // === Execute First Partial Fill ===
        // Taker buys 25 TokenA for 50 TokenB
        BalanceSnapshot memory before = _getBalances();
        SwapResult memory result = _executeSwapWithEventCheck(order, 50e18, takerData, 50e18, 25e18);
        _verifySwapWithOrderHash(result, before, 50e18, 25e18, expectedOrderHash, "First fill");

        // === Execute Second Partial Fill ===
        // Taker buys another 25 TokenA for 50 TokenB
        before = _getBalances();
        result = _executeSwapWithEventCheck(order, 50e18, takerData, 50e18, 25e18);
        _verifySwapWithOrderHash(result, before, 50e18, 25e18, expectedOrderHash, "Second fill");

        // === Execute Third Partial Fill ===
        // This should work as we haven't exceeded the total balance
        before = _getBalances();
        result = _executeSwapWithEventCheck(order, 80e18, takerData, 80e18, 40e18);
        _verifySwapWithOrderHash(result, before, 80e18, 40e18, expectedOrderHash, "Third fill");

        // === Attempt to Overfill ===
        // Try to buy more than remaining (only 10 TokenA left)
        bytes memory overFillTakerData = _buildTakerData(30e18, signature);
        vm.prank(taker);
        vm.expectRevert(); // Should revert due to invalidator preventing overfill
        swapVM.swap(
            order,
            60e18, // Try to spend 60 TokenB for 30 TokenA (but only 10 left)
            overFillTakerData
        );

        // === Final Fill ===
        // Fill the remaining 10 TokenA for 20 TokenB
        bytes memory finalTakerData = _buildTakerData(10e18, signature);
        before = _getBalances();
        result = _executeSwapWithEventCheck(order, 20e18, finalTakerData, 20e18, 10e18);
        _verifySwapWithOrderHash(result, before, 20e18, 10e18, expectedOrderHash, "Final fill");

        // === Verify Order Fully Filled ===
        // Total filled: 100 TokenA for 200 TokenB (as intended)
        assertEq(tokenA.balanceOf(taker), 100e18, "Total TokenA received incorrect");
        assertEq(tokenB.balanceOf(maker), 200e18, "Total TokenB received by maker incorrect");

        // Try to fill again - should fail as order is fully filled
        vm.prank(taker);
        vm.expectRevert(); // Should revert - order fully filled
        swapVM.swap(
            order,
            1e18, // Try any amount
            takerData
        );
    }

    function test_LimitSwapWithoutInvalidator_ReusableOrder() public {
        // === Build Program WITHOUT Invalidator ===
        // This demonstrates that without invalidator, order can be reused
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: false,  // NO INVALIDATOR - order can be filled multiple times!
            salt: 0
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes32 expectedOrderHash = swapVM.hash(order);

        // Use simplified taker data construction
        bytes memory takerData = _buildTakerData(25e18, signature);

        // First fill - works with event check
        _expectSwappedEvent(order, address(tokenB), address(tokenA), 50e18, 25e18);
        vm.prank(taker);
        (uint256 amountIn1, uint256 amountOut1, bytes32 orderHash1) = swapVM.swap(
            order,
            50e18,
            takerData
        );
        assertEq(amountOut1, 25e18, "Without invalidator: first fill works");
        assertEq(amountIn1, 50e18, "Without invalidator: first fill amountIn correct");
        assertEq(orderHash1, expectedOrderHash, "Without invalidator: first fill orderHash correct");

        // Second fill - also works! (This is the desired behavior for reusable orders)
        _expectSwappedEvent(order, address(tokenB), address(tokenA), 50e18, 25e18);
        vm.prank(taker);
        (uint256 amountIn2, uint256 amountOut2, bytes32 orderHash2) = swapVM.swap(
            order,
            50e18,
            takerData
        );
        assertEq(amountOut2, 25e18, "Without invalidator: order can be reused!");
        assertEq(amountIn2, 50e18, "Without invalidator: second fill amountIn correct");
        assertEq(orderHash2, expectedOrderHash, "Without invalidator: second fill orderHash correct");

        // This demonstrates the difference - invalidators provide fill tracking
    }

    function test_MakerAndTakerTransfers_Permit2() public {
        _installPermit2();

        vm.startPrank(maker);
        tokenA.approve(address(swapVM), 0);
        tokenA.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(tokenA), address(swapVM), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.startPrank(taker);
        tokenB.approve(address(swapVM), 0);
        tokenB.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(tokenB), address(swapVM), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: true,
            useInvalidator: false,
            salt: 0x7777
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature, true);

        BalanceSnapshot memory before = _getBalances();
        SwapResult memory result = _executeSwap(order, 50e18, takerData);

        assertTrue(order.traits.usePermit2());
        _verifySwap(result, before, 50e18, 25e18, "Permit2");
    }

    function test_DirectTransfers_AllModes_Permit2() public {
        _installPermit2();
        Permit2TestLib.approve(address(tokenA), maker, address(swapVM), type(uint160).max, type(uint48).max);
        Permit2TestLib.approve(address(tokenB), taker, address(swapVM), type(uint160).max, type(uint48).max);

        for (uint256 mask = 0; mask < 16; ++mask) {
            bool makerPermit2 = mask & 1 != 0;
            bool takerPermit2 = mask & 2 != 0;
            bool isExactIn = mask & 4 != 0;
            bool isFirstTransferFromTaker = mask & 8 != 0;

            vm.prank(maker);
            tokenA.approve(address(swapVM), makerPermit2 ? 0 : type(uint256).max);
            vm.prank(taker);
            tokenB.approve(address(swapVM), takerPermit2 ? 0 : type(uint256).max);

            MakerSetup memory setup = MakerSetup({
                balanceA: 100e18,
                balanceB: 200e18,
                tokenIn: address(tokenB),
                tokenOut: address(tokenA),
                usePermit2: makerPermit2,
                useInvalidator: false,
                salt: 0x8000 + mask
            });
            (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
            bytes memory takerData = _buildTakerData(0, signature, takerPermit2, isExactIn, isFirstTransferFromTaker);

            BalanceSnapshot memory before = _getBalances();
            SwapResult memory result = _executeSwap(order, isExactIn ? 50e18 : 25e18, takerData);

            assertEq(order.traits.usePermit2(), makerPermit2, "Incorrect maker Permit2 trait");
            _verifySwap(result, before, 50e18, 25e18, "Permit2 mode");
        }

        assertEq(Permit2TestLib.allowance(maker, address(tokenA), address(swapVM)).amount, type(uint160).max, "Unlimited maker allowance changed");
        assertEq(Permit2TestLib.allowance(taker, address(tokenB), address(swapVM)).amount, type(uint160).max, "Unlimited taker allowance changed");
    }

    function test_TakerWithoutTokenApproval_Permit2_Reverts() public {
        _installPermit2();

        vm.prank(taker);
        IPermit2(PERMIT2).approve(address(tokenB), address(swapVM), type(uint160).max, type(uint48).max);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: false,
            salt: 0x7778
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature, true);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swapVM.swap(order, 50e18, takerData);
    }

    function test_MakerWithoutTokenApproval_Permit2_Reverts() public {
        _installPermit2();

        vm.prank(maker);
        IPermit2(PERMIT2).approve(address(tokenA), address(swapVM), type(uint160).max, type(uint48).max);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: true,
            useInvalidator: false,
            salt: 0x7779
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swapVM.swap(order, 50e18, takerData);
    }

    function test_TakerExpiredInternalAllowance_Permit2_Reverts() public {
        _installPermit2();
        vm.warp(100);
        Permit2TestLib.approve(address(tokenB), taker, address(swapVM), 50e18, 99);

        vm.prank(taker);
        tokenB.approve(address(swapVM), 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: false,
            salt: 0x777A
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swapVM.swap(order, 50e18, _buildTakerData(25e18, signature, true));
    }

    function test_MakerExpiredInternalAllowance_Permit2_Reverts() public {
        _installPermit2();
        vm.warp(100);
        Permit2TestLib.approve(address(tokenA), maker, address(swapVM), 25e18, 99);

        vm.prank(maker);
        tokenA.approve(address(swapVM), 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: true,
            useInvalidator: false,
            salt: 0x777B
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swapVM.swap(order, 50e18, _buildTakerData(25e18, signature));
    }

    function test_AllowanceExpiringNow_Permit2_Succeeds() public {
        _installPermit2();
        vm.warp(100);
        Permit2TestLib.approve(address(tokenA), maker, address(swapVM), 25e18, 100);
        Permit2TestLib.approve(address(tokenB), taker, address(swapVM), 50e18, 100);

        vm.prank(maker);
        tokenA.approve(address(swapVM), 0);
        vm.prank(taker);
        tokenB.approve(address(swapVM), 0);

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: true,
            useInvalidator: false,
            salt: 0x777C
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        _executeSwap(order, 50e18, _buildTakerData(25e18, signature, true));

        assertEq(Permit2TestLib.allowance(maker, address(tokenA), address(swapVM)).amount, 0);
        assertEq(Permit2TestLib.allowance(taker, address(tokenB), address(swapVM)).amount, 0);
    }

    function test_AmountAboveUint160_Permit2_Reverts() public {
        uint256 amount = uint256(type(uint160).max) + 1;
        MakerSetup memory setup = MakerSetup({
            balanceA: amount,
            balanceB: amount,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: false,
            salt: 0x777D
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.Permit2TransferAmountTooHigh.selector);
        swapVM.swap(order, amount, _buildTakerData(0, signature, true));
    }

    function test_TakerInternalAllowanceConsumed_Permit2_Reverts() public {
        _installPermit2();

        vm.startPrank(taker);
        tokenB.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(tokenB), address(swapVM), 50e18, type(uint48).max);
        vm.stopPrank();

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: false,
            salt: 0x7780
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature, true);

        _executeSwap(order, 50e18, takerData);
        assertEq(Permit2TestLib.allowance(taker, address(tokenB), address(swapVM)).amount, 0);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swapVM.swap(order, 50e18, takerData);
    }

    function test_MakerInternalAllowanceConsumed_Permit2_Reverts() public {
        _installPermit2();

        vm.startPrank(maker);
        tokenA.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(tokenA), address(swapVM), 25e18, type(uint48).max);
        vm.stopPrank();

        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: true,
            useInvalidator: false,
            salt: 0x7781
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(25e18, signature);

        _executeSwap(order, 50e18, takerData);
        assertEq(Permit2TestLib.allowance(maker, address(tokenA), address(swapVM)).amount, 0);

        vm.prank(taker);
        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swapVM.swap(order, 50e18, takerData);
    }

    function test_MakerTraits_Permit2WithAqua_RevertsInBuilder() public {
        MakerTraitsLib.Args memory args;
        args.maker = maker;
        args.tokenA = address(tokenA);
        args.tokenB = address(tokenB);
        args.useAquaInsteadOfSignature = true;
        args.usePermit2 = true;

        vm.expectRevert(MakerTraitsLib.MakerTraitsPermit2IsIncompatibleWithAqua.selector);
        this.buildOrder(args);
    }

    function buildOrder(MakerTraitsLib.Args memory args) external pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(args);
    }

    function _installPermit2() private {
        Permit2TestLib.install();
    }

    function test_SwappedEvent_EmitsCorrectParameters() public {
        // === Setup ===
        MakerSetup memory setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            usePermit2: false,
            useInvalidator: false,
            salt: 0x9999
        });
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(setup);
        bytes memory takerData = _buildTakerData(50e18, signature);
        bytes32 expectedOrderHash = swapVM.hash(order);

        // === Verify Event Parameters ===
        vm.expectEmit(true, true, true, true, address(swapVM));
        emit SwapVM.Swapped(
            expectedOrderHash,
            maker,
            taker,
            address(tokenB),  // tokenIn
            address(tokenA),  // tokenOut
            100e18,           // amountIn
            50e18             // amountOut
        );

        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut, bytes32 orderHash) = swapVM.swap(
            order,
            100e18,
            takerData
        );

        // Verify return values match event
        assertEq(amountIn, 100e18, "amountIn should match");
        assertEq(amountOut, 50e18, "amountOut should match");
        assertEq(orderHash, expectedOrderHash, "orderHash should match");
    }
}
