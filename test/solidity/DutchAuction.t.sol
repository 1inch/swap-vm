// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVM } from "../../contracts/SwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { Time } from "../../contracts/libs/Time.sol";
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
    using Math for uint256;

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
     * Test Dutch auction out stops at the order balance
     */
    function test_DutchAuctionOut_CapsAtBaseBalance() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint64 decayFactor = 0.99e18;
        uint24 surchargeBps = 0.5e7;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceOut.build(startTime, decayFactor, surchargeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.warp(startTime + 300);

        TokenMock(address(tokenA)).mint(taker, 10e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order,
            10e18,
            exactInData
        );
        assertEq(amountIn, 10e18);
        assertEq(amountOut, 20e18);
    }

    /**
     * Test Dutch auction in stops at the order balance
     */
    function test_DutchAuctionIn_CapsAtBaseBalance() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint64 decayFactor = 0.99e18;
        uint24 surchargeBps = 0.5e7;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceIn.build(startTime, decayFactor, surchargeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.warp(startTime + 300);

        TokenMock(address(tokenA)).mint(taker, 10e18);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            order,
            10e18,
            exactInData
        );
        assertEq(amountIn, 10e18);
        assertEq(amountOut, 20e18);
    }

    /**
     * Test DutchAuctionBalanceIn exact decay amount.
     */
    function test_DutchAuctionIn_ExactDecayedAmount() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint64 decayFactor = 0.75e18; // 25% loss every second
        uint24 surchargeBps = 0.6e7; // 60% initial surcharge

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceIn.build(startTime, decayFactor, surchargeBps),
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
        vm.assertEq(amountOut, 12.5e18, "Invalid amountOut");

        // After one second balanceIn is 100e18 * 1.6 * 0.75 = 120e18.
        vm.warp(startTime + 1);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 16_666_666_666_666_666_666, "Invalid amountOut");

        // After two seconds the decayed surcharge is exhausted and balanceIn stays at 100e18.
        vm.warp(startTime + 2);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 20e18, "Invalid amountOut");
    }

    /**
     * Test DutchAuctionBalanceOut exact decay amount.
     */
    function test_DutchAuctionOut_ExactDecayedAmount() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint64 decayFactor = 0.75e18; // 25% loss every second
        uint24 surchargeBps = 0.6e7; // 60% initial surcharge

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceOut.build(startTime, decayFactor, surchargeBps),
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
        vm.assertEq(amountOut, 12.5e18, "Invalid amountOut");

        // After one second balanceOut is 200e18 / (1.6 * 0.75).
        vm.warp(startTime + 1);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 16_666_666_666_666_666_666, "Invalid amountOut");

        // After two seconds the decayed surcharge is exhausted and balanceOut stays at 200e18.
        vm.warp(startTime + 2);
        TokenMock(address(tokenA)).mint(taker, 10e18);
        (amountIn, amountOut, ) = swapVM.swap(order, 10e18, exactInData);
        vm.assertEq(amountIn, 10e18, "Nothing must happen with amountIn");
        vm.assertEq(amountOut, 20e18, "Invalid amountOut");
    }

    function testFuzz_DutchAuction_InAndOutQuotesMatch(uint256 balanceIn, uint256 balanceOut) public {
        balanceIn = bound(balanceIn, 4, 1e32);
        balanceOut = bound(balanceOut, 4, 1e32);

        uint40 timestamp = AUCTION_REALISTIC_START_TS;
        uint64 decay = 0.999e18;
        uint24 surchargeBps = 0.5e7;

        ISwapVM.Order memory orderIn = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            DutchAuctionBalanceIn.build(timestamp, decay, surchargeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        ISwapVM.Order memory orderOut = _createOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            DutchAuctionBalanceOut.build(timestamp, decay, surchargeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));

        bytes memory takerDataExactInForInOrder = _signAndPackTakerData(orderIn, true, 0, true);
        bytes memory takerDataExactInForOutOrder = _signAndPackTakerData(orderOut, true, 0, true);
        bytes memory takerDataExactOutForInOrder = _signAndPackTakerData(orderIn, false, 0, true);
        bytes memory takerDataExactOutForOutOrder = _signAndPackTakerData(orderOut, false, 0, true);

        uint256[7] memory offsets = [uint256(0), 12, 13, 25, 100, 175, 200];
        for (uint256 i; i < offsets.length; i++) {
            vm.warp(uint256(timestamp) + offsets[i]);

            (uint256 amountInFromInOrder,,) = swapVM.quote(orderIn, balanceOut / 2, takerDataExactOutForInOrder);
            (uint256 amountInFromOutOrder,,) = swapVM.quote(orderOut, balanceOut / 2, takerDataExactOutForOutOrder);

            (,uint256 amountOutFromInOrder,) = swapVM.quote(orderIn, balanceIn / 2, takerDataExactInForInOrder);
            (,uint256 amountOutFromOutOrder,) = swapVM.quote(orderOut, balanceIn / 2, takerDataExactInForOutOrder);

            assertApproxEqAbs(amountInFromInOrder, amountInFromOutOrder, 2 * balanceIn.ceilDiv(balanceOut));
            assertApproxEqAbs(amountOutFromInOrder, amountOutFromOutOrder, 2 * balanceOut.ceilDiv(balanceIn));
        }
    }

    function test_DutchAuctionBalanceIn_RelativeToOrderAnnouncement() public {
        uint40 announcedAt = 1_000_000;
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceIn.build(Time.RELATIVE_TIME_FLAG, 0.5e18, 0.5e7),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        vm.warp(announcedAt);
        tokenA.mint(taker, 10e18);
        (, uint256 amountOut,) = swapVM.swap(order, 10e18, takerData);
        assertEq(amountOut, 13_333_333_333_333_333_333);
        assertEq(swapVM.announcedAt(swapVM.hash(order)), announcedAt);

        vm.warp(announcedAt + 1);
        (, amountOut,) = swapVM.quote(order, 10e18, takerData);
        assertEq(amountOut, 20e18);
    }

    function test_DutchAuctionBalanceOut_RelativeToOrderAnnouncement() public {
        uint40 announcedAt = 1_000_000;
        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            DutchAuctionBalanceOut.build(Time.RELATIVE_TIME_FLAG, 0.5e18, 0.5e7),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory takerData = _signAndPackTakerData(order, true, 0);

        vm.warp(announcedAt);
        tokenA.mint(taker, 10e18);
        (, uint256 amountOut,) = swapVM.swap(order, 10e18, takerData);
        assertEq(amountOut, 13_333_333_333_333_333_333);
        assertEq(swapVM.announcedAt(swapVM.hash(order)), announcedAt);

        vm.warp(announcedAt + 1);
        (, amountOut,) = swapVM.quote(order, 10e18, takerData);
        assertEq(amountOut, 20e18);
    }

    /**
     * Test DutchAuctionBalanceOut rounds inverse decay up.
     */
    function test_DutchAuctionOut_RoundingUp() public {
        uint40 startTime = AUCTION_REALISTIC_START_TS;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e18, 10),
            DutchAuctionBalanceOut.build(startTime, 0.9e18, 0.9e7),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        vm.warp(startTime + 1);
        (, uint256 amountOut,) = swapVM.quote(order, 1e18, exactInData);
        vm.assertEq(amountOut, 6, "Invalid rounded amountOut");
    }

    /**
     * Test Dutch auction build rejects invalid decay and surcharge values.
     */
    function test_Fail_DutchAuctionInvalidDecay() public {
        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceIn.DutchAuctionWrongDecayFactor.selector, uint64(1e18)));
        this.buildDutchAuctionBalanceIn(AUCTION_REALISTIC_START_TS, 1e18, 0.1e7);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceOut.DutchAuctionWrongDecayFactor.selector, uint64(1e18)));
        this.buildDutchAuctionBalanceOut(AUCTION_REALISTIC_START_TS, 1e18, 0.1e7);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceIn.DutchAuctionWrongDecayFactor.selector, uint64(1e18 + 1)));
        this.buildDutchAuctionBalanceIn(AUCTION_REALISTIC_START_TS, 1e18 + 1, 0.1e7);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceOut.DutchAuctionWrongDecayFactor.selector, uint64(1e18 + 1)));
        this.buildDutchAuctionBalanceOut(AUCTION_REALISTIC_START_TS, 1e18 + 1, 0.1e7);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceIn.DutchAuctionSurchargeOutOfRange.selector, uint24(1e7)));
        this.buildDutchAuctionBalanceIn(AUCTION_REALISTIC_START_TS, 0.99e18, 1e7);

        vm.expectRevert(abi.encodeWithSelector(DutchAuctionBalanceOut.DutchAuctionSurchargeOutOfRange.selector, uint24(1e7)));
        this.buildDutchAuctionBalanceOut(AUCTION_REALISTIC_START_TS, 0.99e18, 1e7);
    }

    /// @dev Simple wrapper over library function `DutchAuctionBalanceIn.build`.
    function buildDutchAuctionBalanceIn(uint40 start, uint64 decay, uint24 surchargeBps) external pure {
        DutchAuctionBalanceIn.build(start, decay, surchargeBps);
    }

    /// @dev Simple wrapper over library function `DutchAuctionBalanceOut.build`.
    function buildDutchAuctionBalanceOut(uint40 start, uint64 decay, uint24 surchargeBps) external pure {
        DutchAuctionBalanceOut.build(start, decay, surchargeBps);
    }
    /**
     * Helper to test Dutch auction with specific decay factor
     */
    function _testDutchAuctionWithDecay(uint64 decayFactor, bool useIn) private {
        uint40 startTime = AUCTION_REALISTIC_START_TS;
        uint24 surchargeBps = 0.5e7;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(1e30, 2e30),
            useIn ?
                DutchAuctionBalanceIn.build(startTime, decayFactor, surchargeBps) :
                DutchAuctionBalanceOut.build(startTime, decayFactor, surchargeBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0);

        // Test at different time points
        uint256[] memory timeOffsets = new uint256[](4);
        timeOffsets[0] = 0;     // Start
        timeOffsets[1] = 60;    // 1 minute
        timeOffsets[2] = 150;   // 2.5 minutes
        timeOffsets[3] = 299;

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
            // So for the same input amount, output grows until it reaches the order balance
            for (uint256 i = 1; i < outputs.length; i++) {
                assertGe(outputs[i], outputs[i-1], "Output should not decrease over time for balance in decay");
            }
        } else {
            // For balance out decay: as time passes, the effective balance out INCREASES
            // (dividing by smaller decay factor increases the balance)
            // This also makes the price better for the taker
            // So for the same input amount, output grows until it reaches the order balance
            for (uint256 i = 1; i < outputs.length; i++) {
                assertGe(outputs[i], outputs[i-1], "Output should not decrease over time for balance out decay");
            }
        }
        assertGt(outputs[outputs.length - 1], outputs[0], "Auction should improve the taker price");
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
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
            usePermit2: false,
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
