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

contract TakerTraitsPartialFillTest is Test {
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

    function testFuzz_AllowPartialFill_ExactIn(uint256 amount, uint256 amountPartial, bool allowPartialFill, bool amountMode) public view {
        amount = bound(amount, 0, amountMode ? 1e50 : 100);
        amountPartial = bound(amountPartial, 0, amount * 2);

        ISwapVM.Order memory order = _createOrder(_patchProgram(amountPartial, 1e18));
        (bool ok, bytes4 selector) = _tryQuote(order, amount, _makeTakerData(true, allowPartialFill, false, ""));

        if (allowPartialFill) {
            assertEq(ok, amountPartial <= amount, "Partial fill should pass up to the taker amount");
            if (!ok) assertEq(selector, TakerTraitsLib.TakerTraitsTakerAmountInExceed.selector);
        } else {
            assertEq(ok, amountPartial == amount, "Only exact fill should pass");
            if (!ok) assertEq(selector, TakerTraitsLib.TakerTraitsTakerAmountInMismatch.selector);
        }
    }

    function testFuzz_AllowPartialFill_ExactOut(uint256 amount, uint256 amountPartial, bool allowPartialFill, bool amountMode) public view {
        amount = bound(amount, 0, amountMode ? 1e50 : 100);
        amountPartial = bound(amountPartial, 0, amount * 2);

        ISwapVM.Order memory order = _createOrder(_patchProgram(1e18, amountPartial));
        (bool ok, bytes4 selector) = _tryQuote(order, amount, _makeTakerData(false, allowPartialFill, false, ""));

        if (allowPartialFill) {
            assertEq(ok, amountPartial <= amount && amountPartial > 0, "Partial fill should pass up to the taker amount");
            if (!ok && amountPartial > amount) assertEq(selector, TakerTraitsLib.TakerTraitsTakerAmountOutExceed.selector);
            if (!ok && amountPartial == 0) assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
        } else {
            assertEq(ok, amountPartial == amount && amountPartial > 0, "Only exact fill should pass");
            if (!ok && amountPartial > 0) assertEq(selector, TakerTraitsLib.TakerTraitsTakerAmountOutMismatch.selector);
            if (!ok && amountPartial == 0) assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
        }
    }

    function testFuzz_StrictThreshold_ExactIn(uint256 amount, uint256 amountPartial, uint256 thresholdAmount, uint256 amountOut, bool amountMode) public view {
        amount = bound(amount, 0, amountMode ? 1e50 : 100);
        amountPartial = bound(amountPartial, 0, amount);
        thresholdAmount = bound(thresholdAmount, 0, amountMode ? 1e50 : 100);
        amountOut = bound(amountOut, 0, thresholdAmount * 2);

        ISwapVM.Order memory order = _createOrder(_patchProgram(amountPartial, amountOut));
        (bool ok, bytes4 selector) = _tryQuote(order, amount, _makeTakerData(true, true, true, abi.encodePacked(thresholdAmount)));

        // Strict threshold requires the exact amountOut and does not scale with the fill
        assertEq(ok, amountOut == thresholdAmount && amountOut > 0, "Only exact threshold amountOut should pass");
        if (!ok && amountOut > 0) assertEq(selector, TakerTraitsLib.TakerTraitsNonExactThresholdAmountOut.selector);
        if (!ok && amountOut == 0) assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
    }

    function testFuzz_StrictThreshold_ExactOut(uint256 amount, uint256 amountPartial, uint256 thresholdAmount, uint256 amountIn, bool amountMode) public view {
        amount = bound(amount, 0, amountMode ? 1e50 : 100);
        amountPartial = bound(amountPartial, 0, amount);
        thresholdAmount = bound(thresholdAmount, 0, amountMode ? 1e50 : 100);
        amountIn = bound(amountIn, 0, thresholdAmount * 2);

        ISwapVM.Order memory order = _createOrder(_patchProgram(amountIn, amountPartial));
        (bool ok, bytes4 selector) = _tryQuote(order, amount, _makeTakerData(false, true, true, abi.encodePacked(thresholdAmount)));

        // Strict threshold requires the exact amountIn and does not scale with the fill
        assertEq(ok, amountIn == thresholdAmount && amountPartial > 0, "Only exact threshold amountIn should pass");
        if (!ok && amountPartial > 0) assertEq(selector, TakerTraitsLib.TakerTraitsNonExactThresholdAmountIn.selector);
        if (!ok && amountPartial == 0) assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
    }

    function testFuzz_ScaledThreshold_ExactIn(uint256 amount, uint256 amountPartial, uint256 thresholdAmount, uint256 amountOut, bool amountMode) public view {
        amount = bound(amount, 0, amountMode ? 1e50 : 100);
        amountPartial = bound(amountPartial, 0, amount);
        thresholdAmount = bound(thresholdAmount, 0, amountMode ? 1e50 : 100);
        amountOut = bound(amountOut, 0, thresholdAmount * 2);
        uint256 minAmountOut = amount == 0 ? thresholdAmount : thresholdAmount.mulDiv(amountPartial, amount, Math.Rounding.Ceil);

        ISwapVM.Order memory order = _createOrder(_patchProgram(amountPartial, amountOut));
        (bool ok, bytes4 selector) = _tryQuote(order, amount, _makeTakerData(true, true, false, abi.encodePacked(thresholdAmount)));

        assertEq(ok, amountOut >= minAmountOut && amountOut > 0, "Scaled min output should pass at the exact wei");
        if (!ok && amountOut > 0) assertEq(selector, TakerTraitsLib.TakerTraitsInsufficientMinOutputAmount.selector);
        if (!ok && amountOut == 0) assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
    }

    function testFuzz_ScaledThreshold_ExactOut(uint256 amount, uint256 amountPartial, uint256 thresholdAmount, uint256 amountIn, bool amountMode) public view {
        amount = bound(amount, 0, amountMode ? 1e50 : 100);
        amountPartial = bound(amountPartial, 0, amount);
        thresholdAmount = bound(thresholdAmount, 0, amountMode ? 1e50 : 100);
        amountIn = bound(amountIn, 0, thresholdAmount * 2);
        uint256 maxAmountIn = amount == 0 ? thresholdAmount : thresholdAmount.mulDiv(amountPartial, amount);

        ISwapVM.Order memory order = _createOrder(_patchProgram(amountIn, amountPartial));
        (bool ok, bytes4 selector) = _tryQuote(order, amount, _makeTakerData(false, true, false, abi.encodePacked(thresholdAmount)));

        assertEq(ok, amountIn <= maxAmountIn && amountPartial > 0, "Scaled max input should pass at the exact wei");
        if (!ok && amountPartial > 0) assertEq(selector, TakerTraitsLib.TakerTraitsExceedingMaxInputAmount.selector);
        if (!ok && amountPartial == 0) assertEq(selector, TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
    }

    function _patchProgram(uint256 amountIn, uint256 amountOut) internal pure returns (bytes memory) {
        return PatchSwapRegisters.build(SwapRegisters({
            balanceIn: 0,
            balanceOut: 0,
            amountIn: amountIn,
            amountOut: amountOut
        }));
    }

    function _tryQuote(ISwapVM.Order memory order, uint256 amount, bytes memory takerData) internal view returns (bool ok, bytes4 selector) {
        try swapVM.asView().quote(order, amount, takerData) returns (uint256, uint256, bytes32) {
            return (true, bytes4(0));
        } catch (bytes memory reason) {
            return (false, bytes4(reason));
        }
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

    function _makeTakerData(bool isExactIn, bool allowPartialFill, bool isStrictThresholdAmount, bytes memory threshold) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: isStrictThresholdAmount,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: allowPartialFill,
            threshold: threshold,
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
