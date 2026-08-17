// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { Strategies } from "../src/strategies/Strategies.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { LimitSwap } from "../src/instructions/LimitSwap.sol";
import { XYCConcentrateSwap } from "../src/instructions/XYCConcentrate.sol";
import { FeeFlatIn } from "../src/instructions/FeeFlat.sol";
import { Deadline, Salt, Stop } from "../src/instructions/Controls.sol";

/**
 * @title Strategies
 * @notice Tests for Strategies order builders
 */
contract StrategiesTest is Test {
    Aqua public aqua;
    SwapVMRouter public swapVM;
    address public tokenA;
    address public tokenB;

    uint256 public makerPK = 0x1234;
    address public maker = vm.addr(0x1234);

    function setUp() public {
        aqua = new Aqua();
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        (tokenA, tokenB) = (makeAddr("token1"), makeAddr("token2"));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }
    function test_Strategies_BuildLimitOrder() public view {
        Strategies.LimitOrder memory args = Strategies.LimitOrder({
            balanceA: 100e18,
            balanceB: 200e18,
            direction: true
        });

        assertEq(this.limitOrder(new bytes[](0), args), bytes.concat(
            StaticBalances.build(100e18, 200e18),
            LimitSwap.build(true)
        ));
    }

    function test_Strategies_BuildLimitOrderWithPrefix() public view {
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = Deadline.build(uint40(1e9));
        prefix[1] = Salt.build(uint64(42));

        Strategies.LimitOrder memory args = Strategies.LimitOrder({
            balanceA: 100e18,
            balanceB: 200e18,
            direction: false
        });

        assertEq(this.limitOrder(prefix, args), bytes.concat(
            Deadline.build(uint40(1e9)),
            Salt.build(uint64(42)),
            StaticBalances.build(100e18, 200e18),
            LimitSwap.build(false)
        ));
    }

    function test_Strategies_BuildXYCConcentrateOrder() public view {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = Salt.build(uint64(42));

        Strategies.XYCConcentrateOrder memory args = Strategies.XYCConcentrateOrder({
            sqrtPriceMin: 0.9e18,
            sqrtPriceMax: 1.1e18,
            feeBps: 30000
        });

        assertEq(this.xycConcentrateOrder(prefix, args), bytes.concat(
            Salt.build(uint64(42)),
            FeeFlatIn.build(30000),
            XYCConcentrateSwap.build(0.9e18, 1.1e18)
        ));
    }

    function test_Strategies_RevertPrefixUnregistered() public {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = Stop.build();

        vm.expectRevert(abi.encodeWithSelector(Strategies.PrefixUnregistered.selector, uint8(uint256(Stop.opcode))));
        this.limitOrder(prefix, Strategies.LimitOrder({ balanceA: 1, balanceB: 1, direction: true }));
    }

    function test_Strategies_RevertPrefixTruncated() public {
        bytes memory instruction = Deadline.build(uint40(1e9));
        bytes memory truncated = new bytes(instruction.length - 1);
        for (uint256 i; i < truncated.length; i++) truncated[i] = instruction[i];

        bytes[] memory prefix = new bytes[](1);
        prefix[0] = truncated;

        vm.expectRevert(abi.encodeWithSelector(Strategies.PrefixInvalidLength.selector, 6, 7));
        this.limitOrder(prefix, Strategies.LimitOrder({ balanceA: 1, balanceB: 1, direction: true }));
    }

    function test_Strategies_RevertPrefixPadded() public {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = bytes.concat(Deadline.build(uint40(1e9)), hex"00");

        vm.expectRevert(abi.encodeWithSelector(Strategies.PrefixInvalidLength.selector, 8, 7));
        this.limitOrder(prefix, Strategies.LimitOrder({ balanceA: 1, balanceB: 1, direction: true }));
    }

    function test_Strategies_RevertFeeBpsOutOfRange() public {
        Strategies.XYCConcentrateOrder memory args = Strategies.XYCConcentrateOrder({
            sqrtPriceMin: 0.9e18,
            sqrtPriceMax: 1.1e18,
            feeBps: 1e7
        });

        vm.expectRevert(abi.encodeWithSelector(FeeFlatIn.FeeBpsOutOfRange.selector, 1e7));
        this.xycConcentrateOrder(new bytes[](0), args);
    }

    function test_Strategies_RevertInvalidPriceBounds() public {
        Strategies.XYCConcentrateOrder memory args = Strategies.XYCConcentrateOrder({
            sqrtPriceMin: 1.1e18,
            sqrtPriceMax: 0.9e18,
            feeBps: 30000
        });

        vm.expectRevert(abi.encodeWithSelector(XYCConcentrateSwap.ConcentrateInvalidPriceBounds.selector, 1.1e18, 0.9e18));
        this.xycConcentrateOrder(new bytes[](0), args);
    }

    function testFuzz_Strategies_QuoteLimitOrderRate(uint256 balanceA, uint256 balanceB, uint256 amountIn) public view {
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        amountIn = bound(amountIn, 1e12, balanceA);

        ISwapVM.Order memory order = _order(this.limitOrder(new bytes[](0), Strategies.LimitOrder({
            balanceA: balanceA,
            balanceB: balanceB,
            direction: true
        })), false);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amountIn, _takerData(abi.encodePacked(r, s, v), true));

        assertEq(quotedIn, amountIn);
        // Maker gets the order rate or better
        assertLe(quotedOut * balanceA, quotedIn * balanceB);
    }

    function testFuzz_Strategies_QuoteXYCConcentrateOrderInBounds(
        uint256 balanceA,
        uint256 balanceB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 amountIn,
        uint256 feeBps,
        bool isAToB
    ) public {
        feeBps = bound(feeBps, 0, 0.01e7);
        balanceA = bound(balanceA, 1e18, 1e27);
        balanceB = bound(balanceB, 1e18, 1e27);
        sqrtPriceMin = bound(sqrtPriceMin, 0.1e18, 10e18);
        sqrtPriceMax = bound(sqrtPriceMax, sqrtPriceMin * 2, 20e18);
        uint256 balanceIn = isAToB ? balanceA : balanceB;
        amountIn = bound(amountIn, balanceIn / 1e4 + 1, balanceIn * 100);

        ISwapVM.Order memory order = _order(this.xycConcentrateOrder(new bytes[](0), Strategies.XYCConcentrateOrder({
            sqrtPriceMin: sqrtPriceMin,
            sqrtPriceMax: sqrtPriceMax,
            feeBps: uint24(feeBps)
        })), true);

        // AMM order takes balances from Aqua
        vm.prank(maker);
        aqua.ship(address(swapVM), abi.encode(order), dynamic([tokenA, tokenB]), dynamic([balanceA, balanceB]));

        (uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(order, amountIn, _takerData("", isAToB));

        // Maker never pays out beyond the shipped reserves and never sells cheaper than the direction's range corner
        if (isAToB) {
            assertLe(quotedOut, balanceB);
            assertLe(quotedOut * 1e36, quotedIn * sqrtPriceMax * sqrtPriceMax);
        } else {
            assertLe(quotedOut, balanceA);
            assertLe(quotedOut * sqrtPriceMin * sqrtPriceMin, quotedIn * 1e36);
        }
    }

    function _order(bytes memory program, bool useAqua) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: useAqua,
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

    function _takerData(bytes memory signature, bool isAToB) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: true,
            threshold: "",
            to: address(0),
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
    }

    // Externals routing memory test data into the calldata-only builders

    function limitOrder(bytes[] calldata prefix, Strategies.LimitOrder calldata args) external pure returns (bytes memory) {
        return Strategies.buildLimitOrder(prefix, args);
    }

    function xycConcentrateOrder(
        bytes[] calldata prefix,
        Strategies.XYCConcentrateOrder calldata args
    ) external pure returns (bytes memory) {
        return Strategies.buildXYCConcentrateOrder(prefix, args);
    }
}
