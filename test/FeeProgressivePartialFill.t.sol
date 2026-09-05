// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { SwapRegisters } from "../src/libs/VM.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { PatchSwapRegisters } from "../src/instructions/Debug.sol";
import { StaticBalances } from "../src/instructions/Balances.sol";
import { FeeProgressiveIn, FeeProgressiveOut } from "../src/instructions/FeeProgressive.sol";

contract FeeProgressivePartialFillTest is Test {
    using Math for uint256;

    SwapVMRouterDebug public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey = 0x1234;

    function setUp() public {
        maker = vm.addr(makerPrivateKey);
        swapVM = new SwapVMRouterDebug(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token I", "TKI"));
        tokenB = address(new TokenMock("Token J", "TKJ"));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    function testFuzz_FeeProgressiveIn_ExactIn_PartialFill(uint256 amount, uint256 amountPartial, uint256 balance, uint24 feeBps) public view {
        balance = bound(balance, 1, 1e30);
        amount = bound(amount, 0, 1e30);
        feeBps = uint24(bound(feeBps, 0, FeeProgressiveIn.BPS - 1));

        uint256 denominator = FeeProgressiveIn.BPS * balance;
        uint256 fee = (feeBps * amount * amount).ceilDiv(denominator + feeBps * amount);
        amountPartial = bound(amountPartial, 0, amount - fee);
        bool isPartialFill = amountPartial != amount - fee;

        bytes memory program = bytes.concat(
            StaticBalances.build(balance, 1e18),
            FeeProgressiveIn.build(feeBps),
            // Simulates runLoop drifting amountIn down to a partial fill
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: balance,
                balanceOut: 1e18,
                amountIn: amountPartial,
                amountOut: 1e18
            }))
        );

        uint256 realAmount;
        try swapVM.asView().quote(_createOrder(program), amount, _makeTakerData(true))returns (uint256 amountIn, uint256, bytes32) { realAmount = amountIn; }
        catch (bytes memory reason) { require(bytes4(reason) == TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector); }

        uint256 realFee = realAmount - amountPartial;

        uint256 feeDesired = (feeBps * realAmount * realAmount).ceilDiv(denominator + feeBps * realAmount);
        assertEq(realFee, feeDesired);

        // No partial fill -> no drift
        if (!isPartialFill) {
            assertEq(fee, realFee);
            assertEq(amount, realAmount);
        }
        // Partial fill to zero -> no fee
        if (isPartialFill && amountPartial == 0) assertEq(realFee, 0);

        // Drifts only down
        assertLe(realFee, fee);
        assertLe(realAmount, amount);

        // realFee / realAmount >= progressive feeBps
        assertGe(realFee * (denominator + feeBps * realAmount), feeBps * realAmount * realAmount, "Effective fee should favor maker");

        // Imagine realFee is 1 wei less -> realAmount is 1 wei less as well -> progressive feeBps breaks
        if (realFee != 0 && isPartialFill) assertLt((realFee - 1) * (denominator + feeBps * (realAmount - 1)), feeBps * (realAmount - 1) * (realAmount - 1), "One wei less realFee would favor taker");
    }

    function testFuzz_FeeProgressiveIn_ExactOut_PartialFill(uint256 amount, uint256 amountPartial, uint256 amountIn, uint256 balance, uint24 feeBps) public view {
        balance = bound(balance, 1, 1e30);
        amount = bound(amount, 1, 1e30);
        feeBps = uint24(bound(feeBps, 0, FeeProgressiveIn.BPS - 1));

        uint256 denominator = FeeProgressiveIn.BPS * balance;
        amountPartial = bound(amountPartial, 1, amount);
        bool isPartialFill = amountPartial != amount;
        amountIn = bound(amountIn, 0, balance);

        bytes memory program = bytes.concat(
            StaticBalances.build(balance, 1e18),
            FeeProgressiveIn.build(feeBps),
            // Simulates runLoop drifting amountOut down to a partial fill
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: balance,
                balanceOut: 1e18,
                amountIn: amountIn,
                amountOut: amountPartial
            }))
        );

        (uint256 realIn, uint256 realOut,) = swapVM.asView().quote(_createOrder(program), amount, _makeTakerData(false));

        uint256 realFee = realIn - amountIn;

        uint256 feeDesired = (feeBps * amountIn * amountIn).ceilDiv(denominator - feeBps * amountIn);
        assertEq(realFee, feeDesired);

        // No partial fill -> no drift
        if (!isPartialFill) assertEq(realOut, amount);

        // realFee / realIn >= progressive feeBps
        assertGe(realFee * (denominator - feeBps * amountIn), feeBps * amountIn * amountIn, "Effective fee should favor maker");

        // Imagine realFee is 1 wei less -> progressive feeBps breaks
        if (realFee != 0) assertLt((realFee - 1) * (denominator - feeBps * amountIn), feeBps * amountIn * amountIn, "One wei less realFee would favor taker");
    }

    function testFuzz_FeeProgressiveOut_ExactIn_PartialFill(uint256 amount, uint256 amountPartial, uint256 amountOut, uint256 balance, uint24 feeBps) public view {
        balance = bound(balance, 1, 1e30);
        amount = bound(amount, 0, 1e30);
        feeBps = uint24(bound(feeBps, 0, FeeProgressiveOut.BPS - 1));

        uint256 denominator = FeeProgressiveOut.BPS * balance;
        amountPartial = bound(amountPartial, 0, amount);
        bool isPartialFill = amountPartial != amount;
        amountOut = bound(amountOut, 1, 1e30);

        bytes memory program = bytes.concat(
            StaticBalances.build(1e18, balance),
            FeeProgressiveOut.build(feeBps),
            // Simulates runLoop drifting amountIn down to a partial fill
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: 1e18,
                balanceOut: balance,
                amountIn: amountPartial,
                amountOut: amountOut
            }))
        );

        uint256 realIn;
        uint256 realOut;
        try swapVM.asView().quote(_createOrder(program), amount, _makeTakerData(true)) returns (uint256 quotedIn, uint256 quotedOut, bytes32) { (realIn, realOut) = (quotedIn, quotedOut); }
        catch (bytes memory reason) {
            require(bytes4(reason) == TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
            assertEq(amountOut, (feeBps * amountOut * amountOut).ceilDiv(denominator + feeBps * amountOut));
            return;
        }

        uint256 realFee = amountOut - realOut;

        uint256 feeDesired = (feeBps * amountOut * amountOut).ceilDiv(denominator + feeBps * amountOut);
        assertEq(realFee, feeDesired);

        // No partial fill -> no drift
        if (!isPartialFill) assertEq(realIn, amount);

        // realFee / amountOut >= progressive feeBps
        assertGe(realFee * (denominator + feeBps * amountOut), feeBps * amountOut * amountOut, "Effective fee should favor maker");

        // Imagine realFee is 1 wei less -> progressive feeBps breaks
        if (realFee != 0) assertLt((realFee - 1) * (denominator + feeBps * amountOut), feeBps * amountOut * amountOut, "One wei less realFee would favor taker");
    }

    function testFuzz_FeeProgressiveOut_ExactOut_PartialFill(uint256 amount, uint256 amountPartial, uint256 balance, uint24 feeBps) public view {
        balance = bound(balance, 1, 1e30);
        amount = bound(amount, 0, balance);
        feeBps = uint24(bound(feeBps, 0, FeeProgressiveOut.BPS - 1));

        uint256 denominator = FeeProgressiveOut.BPS * balance;
        uint256 fee = (feeBps * amount * amount).ceilDiv(denominator - feeBps * amount);
        amountPartial = bound(amountPartial, 0, amount + fee);
        bool isPartialFill = amountPartial != amount + fee;

        bytes memory program = bytes.concat(
            StaticBalances.build(1e18, balance),
            FeeProgressiveOut.build(feeBps),
            // Simulates runLoop drifting amountOut down to a partial fill
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: 1e18,
                balanceOut: balance,
                amountIn: 1e18,
                amountOut: amountPartial
            }))
        );

        uint256 realAmount;
        try swapVM.asView().quote(_createOrder(program), amount, _makeTakerData(false))returns (uint256, uint256 amountOut, bytes32) { realAmount = amountOut; }
        catch (bytes memory reason) { require(bytes4(reason) == TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector); }

        uint256 realFee = amountPartial - realAmount;

        uint256 feeDesired = (feeBps * amountPartial * amountPartial).ceilDiv(denominator + feeBps * amountPartial);
        assertEq(realFee, feeDesired);

        // No partial fill -> no drift
        if (!isPartialFill) {
            assertEq(fee, realFee);
            assertEq(amount, realAmount);
        }
        // No fill -> no fee
        if (amountPartial == 0) assertEq(0, realFee);

        // Drifts only down
        assertLe(realFee, fee);
        assertLe(realAmount, amount);

        // realFee / amountPartial >= progressive feeBps
        assertGe(realFee * (denominator + feeBps * amountPartial), feeBps * amountPartial * amountPartial, "Effective fee should favor maker");

        // Imagine realFee is 1 wei less -> progressive feeBps breaks
        if (realFee != 0) assertLt((realFee - 1) * (denominator + feeBps * amountPartial), feeBps * amountPartial * amountPartial, "One wei less realFee would favor taker");
    }

    function decodeMismatch(bytes calldata reason) external pure returns (uint256 takerAmount, uint256 computedAmount) {
        return abi.decode(reason[4:], (uint256, uint256));
    }

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: true,
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

    function _makeTakerData(bool isExactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: true,
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
}
