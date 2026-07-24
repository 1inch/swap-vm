// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

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
import { FeeFlatIn, FeeFlatOut } from "../src/instructions/FeeFlat.sol";

contract FeeFlatPartialFillTest is Test {
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

    function testFuzz_FeeFlatIn_PartialFill(uint256 amount, uint256 amountPartial, uint24 feeBps) public view {
        amount = bound(amount, 0, 1e36);
        feeBps = uint24(bound(feeBps, 0, FeeFlatIn.BPS - 1));

        uint256 fee = (amount * feeBps).ceilDiv(FeeFlatIn.BPS);
        amountPartial = bound(amountPartial, 0, amount - fee);
        bool isPartialFill = amountPartial != amount - fee;

        bytes memory program = bytes.concat(
            FeeFlatIn.build(feeBps),
            // Simulates runLoop drifting amountIn down to a partial fill
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: 0,
                balanceOut: 0,
                amountIn: amountPartial,
                amountOut: 1e18
            }))
        );

        uint256 realAmount;
        try swapVM.asView().quote(_createOrder(program), amount, _makeTakerData(true))returns (uint256 amountIn, uint256, bytes32) { realAmount = amountIn; }
        catch (bytes memory reason) { require(bytes4(reason) == TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector); }

        uint256 realFee = realAmount - amountPartial;

        uint256 feeDesired = (realAmount * feeBps).ceilDiv(FeeFlatIn.BPS);
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

        // realFee / realAmount >= feeBps
        assertGe(realFee * FeeFlatIn.BPS, feeBps * realAmount, "Effective fee should favor maker");

        // Imagine realFee is 1 wei less -> realAmount is 1 wei less as well -> feeBps breaks
        if (realFee != 0 && isPartialFill) assertLt((realFee - 1) * FeeFlatIn.BPS, feeBps * (realAmount - 1), "One wei less realFee would favor taker");
    }

    function testFuzz_FeeFlatOut_PartialFill(uint256 amount, uint256 amountPartial, uint24 feeBps) public view {
        amount = bound(amount, 0, 1e36);
        feeBps = uint24(bound(feeBps, 0, FeeFlatOut.BPS - 1));

        uint256 fee = (amount * feeBps).ceilDiv(FeeFlatOut.BPS - feeBps);
        amountPartial = bound(amountPartial, 0, amount + fee);
        bool isPartialFill = amountPartial != amount + fee;

        bytes memory program = bytes.concat(
            FeeFlatOut.build(feeBps),
            // Simulates runLoop drifting amountOut down to a partial fill
            PatchSwapRegisters.build(SwapRegisters({
                balanceIn: 0,
                balanceOut: 0,
                amountIn: 1e18,
                amountOut: amountPartial
            }))
        );

        uint256 realAmount;
        try swapVM.asView().quote(_createOrder(program), amount, _makeTakerData(false))returns (uint256, uint256 amountOut, bytes32) { realAmount = amountOut; }
        catch (bytes memory reason) { require(bytes4(reason) == TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector); }

        uint256 realFee = amountPartial - realAmount;

        uint256 feeDesired = (amountPartial * feeBps).ceilDiv(FeeFlatOut.BPS);
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

        // realFee / amountPartial >= feeBps
        assertGe(realFee * FeeFlatOut.BPS, feeBps * amountPartial, "Effective fee should favor maker");

        // Imagine realFee is 1 wei less -> feeBps breaks
        if (realFee != 0) assertLt((realFee - 1) * FeeFlatOut.BPS, feeBps * amountPartial, "One wei less realFee would favor taker");
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
