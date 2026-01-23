// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";
import { MockTaker } from "./mocks/MockTaker.sol";
import { DirectSwapVMHelper } from "./helpers/DirectSwapVMHelper.sol";
import { AquaSwapVMHelper } from "./helpers/AquaSwapVMHelper.sol";
import { DirectModeTaker } from "./helpers/DirectModeTaker.sol";

import { ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";

/// @title Tests for all 4 combinations of Aqua and direct transfers
/// @notice Tests: Maker(Aqua/Direct) x Taker(AquaPush/Callback/Direct)
contract TransferModesCombinationsTest is Test {
    Aqua public aqua;
    DirectSwapVMHelper public directHelper;
    AquaSwapVMHelper public aquaHelper;

    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker;

    uint256 constant BALANCE_A = 100e18;
    uint256 constant BALANCE_B = 200e18;
    uint256 constant SWAP_AMOUNT = 50e18;

    function setUp() public {
        aqua = new Aqua();

        // Deploy helpers with different opcodes
        directHelper = new DirectSwapVMHelper(address(aqua), vm);
        aquaHelper = new AquaSwapVMHelper(address(aqua));

        // Setup maker
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Setup taker
        taker = makeAddr("taker");

        // Deploy tokens
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
    }

    // ==================== Combination 1: Aqua Maker + Taker AquaPush ====================

    function test_AquaMaker_TakerAquaPush() public {
        AquaSwapVMRouter router = aquaHelper.router();

        // Setup maker's Aqua balances
        tokenA.mint(maker, BALANCE_A);
        tokenB.mint(maker, BALANCE_B);

        ISwapVM.Order memory order = aquaHelper.createOrder(maker, tokenA, tokenB);
        _shipAquaStrategy(order, router);

        // Setup taker with approval for SwapVM to do transferFrom + AquaPush
        tokenB.mint(taker, SWAP_AMOUNT);
        vm.prank(taker);
        tokenB.approve(address(router), type(uint256).max);

        // Build taker data with useTransferFromAndAquaPush = true
        bytes memory takerData = _buildTakerData(taker, true, false);

        // Execute swap
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = router.swap(
            order, address(tokenB), address(tokenA), SWAP_AMOUNT, takerData
        );

        _verifySwapResults(amountIn, amountOut, taker, true);
    }

    // ==================== Combination 2: Aqua Maker + Taker Callback ====================

    function test_AquaMaker_TakerCallback() public {
        // Setup maker's Aqua balances
        tokenA.mint(maker, BALANCE_A);
        tokenB.mint(maker, BALANCE_B);

        ISwapVM.Order memory order = aquaHelper.createOrder(maker, tokenA, tokenB);
        _shipAquaStrategy(order, aquaHelper.router());

        // Setup taker contract with tokens
        MockTaker takerContract = new MockTaker(aqua, aquaHelper.router(), address(this));
        tokenB.mint(address(takerContract), SWAP_AMOUNT);

        // Build taker data with callback (useTransferFromAndAquaPush = false)
        bytes memory takerData = _buildTakerData(address(takerContract), false, true);

        // Execute swap via taker contract
        (uint256 amountIn, uint256 amountOut) = takerContract.swap(
            order, address(tokenB), address(tokenA), SWAP_AMOUNT, takerData
        );

        _verifySwapResults(amountIn, amountOut, address(takerContract), true);
    }

    // ==================== Combination 3: Direct Maker + Taker Direct ====================

    function test_DirectMaker_TakerDirect() public {
        SwapVMRouter router = directHelper.router();

        // Setup maker's token balances with approval
        tokenA.mint(maker, BALANCE_A);
        vm.prank(maker);
        tokenA.approve(address(router), type(uint256).max);

        // Setup taker with approval
        tokenB.mint(taker, SWAP_AMOUNT);
        vm.prank(taker);
        tokenB.approve(address(router), type(uint256).max);

        // Create signed order
        (ISwapVM.Order memory order, bytes memory signature) = directHelper.createSignedOrder(
            maker, makerPrivateKey, tokenA, tokenB, BALANCE_A, BALANCE_B
        );

        // Build taker data with signature
        bytes memory takerData = _buildTakerDataWithSignature(taker, false, signature);

        // Execute swap
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut,) = router.swap(
            order, address(tokenB), address(tokenA), SWAP_AMOUNT, takerData
        );

        _verifySwapResults(amountIn, amountOut, taker, false);
        assertEq(tokenB.balanceOf(maker), SWAP_AMOUNT, "Maker didn't receive tokenB");
    }

    // ==================== Combination 4: Direct Maker + Taker Callback ====================

    function test_DirectMaker_TakerCallback() public {
        SwapVMRouter router = directHelper.router();

        // Setup maker's token balances with approval
        tokenA.mint(maker, BALANCE_A);
        vm.prank(maker);
        tokenA.approve(address(router), type(uint256).max);

        // Create taker contract with tokens and approval (uses DirectModeTaker that doesn't do Aqua push)
        DirectModeTaker takerContract = new DirectModeTaker(router, address(this));
        tokenB.mint(address(takerContract), SWAP_AMOUNT);
        vm.prank(address(takerContract));
        tokenB.approve(address(router), type(uint256).max);

        // Create signed order
        (ISwapVM.Order memory order, bytes memory signature) = directHelper.createSignedOrder(
            maker, makerPrivateKey, tokenA, tokenB, BALANCE_A, BALANCE_B
        );

        // Build taker data with signature and callback
        bytes memory takerData = _buildTakerDataWithSignature(address(takerContract), true, signature);

        // Execute swap via taker contract
        (uint256 amountIn, uint256 amountOut) = takerContract.swap(
            order, address(tokenB), address(tokenA), SWAP_AMOUNT, takerData
        );

        _verifySwapResults(amountIn, amountOut, address(takerContract), false);
        assertEq(tokenB.balanceOf(maker), SWAP_AMOUNT, "Maker didn't receive tokenB");
    }

    // ==================== Helper Functions ====================

    function _shipAquaStrategy(ISwapVM.Order memory order, AquaSwapVMRouter router) internal {
        vm.prank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(aqua), type(uint256).max);

        vm.prank(maker);
        aqua.ship(
            address(router),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([BALANCE_A, BALANCE_B])
        );
    }

    function _buildTakerData(address takerAddr, bool useTransferFromAndAquaPush, bool hasCallback) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
            isExactIn: true,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: hasCallback,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: useTransferFromAndAquaPush,
            threshold: "",
            to: address(0),
            deadline: 0,
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

    function _buildTakerDataWithSignature(address takerAddr, bool hasCallback, bytes memory signature) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddr,
            isExactIn: true,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: hasCallback,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));
    }

    function _verifySwapResults(uint256 amountIn, uint256 amountOut, address recipient, bool isXYC) internal view {
        uint256 expectedOut;
        if (isXYC) {
            // XYC formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
            expectedOut = (SWAP_AMOUNT * BALANCE_A) / (BALANCE_B + SWAP_AMOUNT);
        } else {
            // LimitSwap: 2:1 rate (balanceB / balanceA = 200/100 = 2)
            expectedOut = SWAP_AMOUNT / 2;
        }
        assertEq(amountIn, SWAP_AMOUNT, "Incorrect amountIn");
        assertEq(amountOut, expectedOut, "Incorrect amountOut");
        assertEq(tokenA.balanceOf(recipient), expectedOut, "Recipient didn't receive tokenA");
    }
}
