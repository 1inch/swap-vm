// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";
import { ISwapVM } from "../src/SwapVM.sol";
import { SwapVM } from "../src/SwapVM.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { MockTakerBrokenCallback } from "./mocks/MockTakerBrokenCallback.sol";

/// @title Negative tests for taker transfers in callback through Aqua
/// @notice Tests various failure scenarios when taker callback doesn't properly push tokens to Aqua
contract TakerCallbackAquaNegativeTest is AquaSwapVMTest {

    MockTakerBrokenCallback public brokenTaker;

    uint256 constant SWAP_AMOUNT = 50e18;

    MakerSetup internal _setup;
    ISwapVM.Order internal _order;
    bytes internal _takerDataBytes;

    function setUp() public override {
        super.setUp();
        brokenTaker = new MockTakerBrokenCallback(aqua, swapVM, address(this));

        // Initialize default setup
        _setup = MakerSetup({
            balanceA: 100e18,
            balanceB: 200e18,
            priceMin: 0,
            priceMax: 0,
            protocolFeeBps: 0,
            feeInBps: 0,
            feeOutBps: 0,
            progressiveFeeBps: 0,
            protocolFeeRecipient: address(0),
            swapType: SwapType.XYC
        });

        // Mint tokens to maker
        tokenA.mint(maker, _setup.balanceA);
        tokenB.mint(maker, _setup.balanceB);

        // Create and ship strategy
        _order = createStrategy(_setup);
        shipStrategy(_order, tokenA, tokenB, _setup.balanceA, _setup.balanceB);

        // Mint tokens to taker
        tokenB.mint(address(brokenTaker), SWAP_AMOUNT);

        // Build taker data
        _takerDataBytes = _buildTakerData(address(brokenTaker), true);
    }

    function _buildTakerData(address takerAddress, bool isExactIn) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: takerAddress,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false, // Taker should push via callback
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

    function _executeSwap() internal returns (uint256 amountIn, uint256 amountOut) {
        return brokenTaker.swap(_order, address(tokenB), address(tokenA), SWAP_AMOUNT, _takerDataBytes);
    }

    /// @notice Test: Taker callback doesn't push any tokens to Aqua
    /// @dev Should revert with AquaBalanceInsufficientAfterTakerPush
    function test_TakerCallback_NoPush_Reverts() public {
        brokenTaker.setBehavior(MockTakerBrokenCallback.CallbackBehavior.NoPush);

        // Expect revert: balance stays at 200e18, but we need 200e18 + 50e18 = 250e18
        vm.expectRevert(abi.encodeWithSelector(
            SwapVM.AquaBalanceInsufficientAfterTakerPush.selector,
            _setup.balanceB,  // balance unchanged
            _setup.balanceB,  // original balance
            SWAP_AMOUNT
        ));

        _executeSwap();
    }

    /// @notice Test: Taker callback pushes insufficient tokens to Aqua
    /// @dev Should revert with AquaBalanceInsufficientAfterTakerPush
    function test_TakerCallback_InsufficientPush_Reverts() public {
        uint256 insufficientAmount = SWAP_AMOUNT / 2;
        brokenTaker.setBehavior(MockTakerBrokenCallback.CallbackBehavior.InsufficientPush);
        brokenTaker.setPushAmountOverride(insufficientAmount);

        // Expect revert: balance is 200e18 + 25e18 = 225e18, but we need 250e18
        vm.expectRevert(abi.encodeWithSelector(
            SwapVM.AquaBalanceInsufficientAfterTakerPush.selector,
            _setup.balanceB + insufficientAmount,
            _setup.balanceB,
            SWAP_AMOUNT
        ));

        _executeSwap();
    }

    /// @notice Test: Taker callback pushes tokens to wrong orderHash
    /// @dev Should revert with PushToNonActiveStrategyPrevented from Aqua
    function test_TakerCallback_WrongOrderHash_Reverts() public {
        brokenTaker.setBehavior(MockTakerBrokenCallback.CallbackBehavior.WrongOrderHash);

        vm.expectRevert(); // Aqua.PushToNonActiveStrategyPrevented

        _executeSwap();
    }

    /// @notice Test: Normal callback behavior works correctly (sanity check)
    function test_TakerCallback_Normal_Succeeds() public {
        brokenTaker.setBehavior(MockTakerBrokenCallback.CallbackBehavior.Normal);

        (uint256 amountIn, uint256 amountOut) = _executeSwap();

        // Verify results - XYC formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
        uint256 expectedAmountOut = (SWAP_AMOUNT * _setup.balanceA) / (_setup.balanceB + SWAP_AMOUNT);
        assertEq(amountIn, SWAP_AMOUNT, "Incorrect amountIn");
        assertEq(amountOut, expectedAmountOut, "Incorrect amountOut");
    }

    /// @notice Test: Taker callback pushes exactly 1 wei less than required
    /// @dev Edge case - should revert with AquaBalanceInsufficientAfterTakerPush
    function test_TakerCallback_OneWeiShort_Reverts() public {
        brokenTaker.setBehavior(MockTakerBrokenCallback.CallbackBehavior.InsufficientPush);
        brokenTaker.setPushAmountOverride(SWAP_AMOUNT - 1);

        // Expect revert: balance is 200e18 + (50e18 - 1), but we need 250e18
        vm.expectRevert(abi.encodeWithSelector(
            SwapVM.AquaBalanceInsufficientAfterTakerPush.selector,
            _setup.balanceB + SWAP_AMOUNT - 1,
            _setup.balanceB,
            SWAP_AMOUNT
        ));

        _executeSwap();
    }
}
