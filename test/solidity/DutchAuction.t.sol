// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVM } from "../../contracts/SwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances, DynamicBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { DutchAuctionBalanceIn, DutchAuctionBalanceOut } from "../../contracts/instructions/DutchAuction.sol";

/**
 * @title DutchAuctionTest
 * @notice Tests for DutchAuction functionality
 * @dev Tests time-based price decay behavior
 */
contract DutchAuctionTest is Test, OpcodesDebug {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    // By default foundry's `block.timestamp` returns 1. We prefer to use realistic one.
    uint40 constant AUCTION_REALISTIC_START_TS = 0x123456;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 2e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * Test Dutch auction with different decay factors (balance in)
     */
    function test_DutchAuctionIn_DecayFactors() public {
        uint64[] memory decayFactors = new uint64[](3);
        decayFactors[0] = 0.999e18;  // 0.1% decay per second
        decayFactors[1] = 0.995e18;  // 0.5% decay per second
        decayFactors[2] = 0.99e18;   // 1% decay per second

        for (uint256 i = 0; i < decayFactors.length; i++) {
            _testDutchAuctionWithDecay(decayFactors[i], true);
        }
    }

    /**
     * Test Dutch auction with different decay factors (balance out)
     */
    function test_DutchAuctionOut_DecayFactors() public {
        uint64[] memory decayFactors = new uint64[](3);
        decayFactors[0] = 0.999e18;  // 0.1% decay per second
        decayFactors[1] = 0.995e18;  // 0.5% decay per second
        decayFactors[2] = 0.99e18;   // 1% decay per second

        for (uint256 i = 0; i < decayFactors.length; i++) {
            _testDutchAuctionWithDecay(decayFactors[i], false);
        }
    }

    /**
     * Test Dutch auction out expiry
     */
    function test_DutchAuctionOut_Expiry() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint16 duration = 300; // 5 minutes
        uint64 decayFactor = 0.99e18;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Warp past expiry
        vm.warp(startTime + duration + 1);

        // Should revert on actual swap execution
        TokenMock(address(tokenA)).mint(taker, 10e18);
        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceOut.DutchAuctionExpired.selector, block.timestamp, startTime + duration)); // Dutch auction should revert when expired
        swapVM.swap(
            order,
            10e18,
            exactInData
        );
    }

    /**
     * Test Dutch auction in expiry
     */
    function test_DutchAuctionIn_Expiry() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint16 duration = 300; // 5 minutes
        uint64 decayFactor = 0.99e18;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Warp past expiry
        vm.warp(startTime + duration + 1);

        // Should revert on actual swap execution
        TokenMock(address(tokenA)).mint(taker, 10e18);
        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceIn.DutchAuctionExpired.selector, block.timestamp, startTime + duration)); // Dutch auction should revert when expired
        swapVM.swap(
            order,
            10e18,
            exactInData
        );
    }

    /**
     * Test DutchAuctionBalanceIn exact decay amount.
     */
    function test_DutchAuctionIn_ExactDecayedAmount() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint16 duration = 300; // 5 minutes
        uint64 decayFactor = 0.5e18; // 50% loss every second

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceIn.build(startTime, duration, decayFactor),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256 amountIn;
        uint256 amountOut;

        // Execute swap in the same second when auction is created.
        vm.warp(startTime);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 20e18, "Invalid amountOut");

        // Adjust to time 2 seconds. Price will `P = balanceOut / balanceIn` grow 4 times.
        vm.warp(startTime + 2);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 80e18, "Invalid amountOut");

        // Adjust to time 4 seconds. `balanceIn` has decayed to 6.25e18, below the 10e18 input,
        // so LimitSwap clamps to a partial fill and the taker takes the whole `balanceOut`.
        vm.warp(startTime + 4);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        bytes memory partialFillData = _signAndPackTakerData(order, true, 0, true);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, partialFillData);
        vm.assertEq(amountIn, 6.25e18, "Partial fill must cap amountIn at balanceIn");
        vm.assertEq(amountOut, 200e18, "Invalid amountOut");
    }

    /**
     * Test DutchAuctionBalanceOut exact decay amount.
     */
    function test_DutchAuctionOut_ExactDecayedAmount() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint16 duration = 300; // 5 minutes
        uint64 decayFactor = 0.5e18; // 50% loss every second

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        uint256 amountIn;
        uint256 amountOut;

        // Execute swap in the same second when auction is created.
        vm.warp(startTime);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 20e18, "Invalid amountOut");

        // Adjust to time 2 seconds. Price will `P = balanceOut / balanceIn` grow 4 times.
        vm.warp(startTime + 2);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 80e18, "Invalid amountOut");

        // Adjust to time 4 seconds. `balanceIn` stays at 100e18, so there is no partial fill:
        // `balanceOut` has grown to 3200e18 and the full 10e18 in buys 320e18 out.
        vm.warp(startTime + 4);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 320e18, "Invalid amountOut");
    }

    /**
     * Test Dutch auction build failed for decay < 1.
     */
    function test_Fail_DutchAuctionInvalidDecay() public {
        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceIn.DutchAuctionWrongDecayFactor.selector, uint64(1e18)));
        this.buildDutchAuctionBalanceIn(AUCTION_REALISTIC_START_TS, 300, 1e18);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceOut.DutchAuctionWrongDecayFactor.selector, uint64(1e18)));
        this.buildDutchAuctionBalanceOut(AUCTION_REALISTIC_START_TS, 300, 1e18);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceIn.DutchAuctionWrongDecayFactor.selector, uint64(1e18 + 1)));
        this.buildDutchAuctionBalanceIn(AUCTION_REALISTIC_START_TS, 300, 1e18 + 1);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceOut.DutchAuctionWrongDecayFactor.selector, uint64(1e18 + 1)));
        this.buildDutchAuctionBalanceOut(AUCTION_REALISTIC_START_TS, 300, 1e18 + 1);
    }

    /// @dev Simple wrapper over library function `DutchAuctionBalanceIn.build`.
    function buildDutchAuctionBalanceIn(uint40 start, uint16 duration, uint64 decay) external pure {
        DutchAuctionBalanceIn.build(start, duration, decay);
    }

    /// @dev Simple wrapper over library function `DutchAuctionBalanceOut.build`.
    function buildDutchAuctionBalanceOut(uint40 start, uint16 duration, uint64 decay) external pure {
        DutchAuctionBalanceOut.build(start, duration, decay);
    }
    /**
     * Helper to test Dutch auction with specific decay factor
     */
    function _testDutchAuctionWithDecay(uint64 decayFactor, bool useIn) private {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint16 duration = 300;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            useIn ?
                DutchAuctionBalanceIn.build(startTime, duration, decayFactor) :
                DutchAuctionBalanceOut.build(startTime, duration, decayFactor),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Test at different time points
        uint256[] memory timeOffsets = new uint256[](4);
        timeOffsets[0] = 0;     // Start
        timeOffsets[1] = 60;    // 1 minute
        timeOffsets[2] = 150;   // 2.5 minutes
        timeOffsets[3] = 299;   // Just before expiry

        uint256[] memory outputs = new uint256[](4);

        for (uint256 i = 0; i < timeOffsets.length; i++) {
            // Save snapshot before time manipulation
            uint256 snapshot = vm.snapshot();

            // Warp to test time
            vm.warp(startTime + timeOffsets[i]);

            // Execute swap at this time
            uint256 amountIn = 100e18;
            TokenMock(address(tokenA)).mint(taker, amountIn);

            (uint256 actualIn, uint256 actualOut,) = swapVM.swap(
                order,
                amountIn,
                exactInData
            );

            // Verify swap executed successfully
            assertEq(actualIn, amountIn, "Incorrect amount in");
            assertGt(actualOut, 0, "Should receive tokens out");

            // Store output for later comparison
            outputs[i] = actualOut;

            // Restore snapshot
            vm.revertTo(snapshot);
        }

        // Verify decay behavior
        if (useIn) {
            // For balance in decay: as time passes, the effective balance in decreases
            // This makes the price better for the taker (Dutch auction effect)
            // So for the same input amount, we get MORE output over time
            for (uint256 i = 1; i < outputs.length; i++) {
                assertGt(outputs[i], outputs[i-1], "Output should increase over time for balance in decay");
            }
        } else {
            // For balance out decay: as time passes, the effective balance out INCREASES
            // (dividing by smaller decay factor increases the balance)
            // This also makes the price better for the taker
            // So for the same input amount, we get MORE output over time
            for (uint256 i = 1; i < outputs.length; i++) {
                assertGt(outputs[i], outputs[i-1], "Output should increase over time for balance out decay");
            }
        }
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
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
            program: program
        }));
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) private view returns (bytes memory) {
        return _signAndPackTakerData(order, isExactIn, threshold, false);
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold,
        bool allowPartialFill
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: allowPartialFill,
            threshold: thresholdData,
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
            signature: signature
        }));

        return abi.encodePacked(takerTraits);
    }
}
