// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { LimitSwapVMRouterDebug } from "../../contracts/routers/LimitSwapVMRouterDebug.sol";
import { LimitOpcodesDebug } from "../../contracts/opcodes/LimitOpcodesDebug.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { PiecewiseLinearSurchargeBalanceIn } from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { FillGridStepwiseAdjusterBalanceIn } from "../../contracts/instructions/FillGridAdjuster.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";

contract FillGridAdjusterTest is Test, LimitOpcodesDebug {
    using Math for uint256;

    Aqua public immutable aqua;
    LimitSwapVMRouterDebug public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    address public maker = address(0xBEEF);

    function setUp() public {
        swapVM = new LimitSwapVMRouterDebug(address(aqua), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
    }

    function test_FillGridStepwiseAdjusterBalanceIn() public {
        uint256 balanceIn = 100e18;
        uint256 balanceOut = 100e18;
        uint24 surchargeScale = uint24((uint256(1) << 24) / 10);

        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = surchargeScale;
        scales[1] = surchargeScale;

        uint24[] memory fillBps = new uint24[](5);
        uint24[] memory adjustBps = new uint24[](5);
        fillBps[0] = 0.1e7; adjustBps[0] = 0.98e7;
        fillBps[1] = 0.3e7; adjustBps[1] = 0.96e7;
        fillBps[2] = 0.5e7; adjustBps[2] = 0.94e7;
        fillBps[3] = 0.7e7; adjustBps[3] = 0.92e7;
        fillBps[4] = 0.9e7; adjustBps[4] = 0.90e7;

        ISwapVM.Order memory order = _buildOrder(bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            PiecewiseLinearSurchargeBalanceIn.build(uint40(block.timestamp), durations, scales),
            FillGridStepwiseAdjusterBalanceIn.build(fillBps, adjustBps),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));
        bytes memory takerData = _buildTakerData(false);

        (uint256 amountIn95,,) = swapVM.quote(order, 95e18, takerData);
        (uint256 amountIn5,,) = swapVM.quote(order, 5e18, takerData);

        uint256 surcharge = PiecewiseLinearSurchargeBalanceIn.scaleValue(balanceIn, surchargeScale);
        uint256 adjustedSurcharge = surcharge * adjustBps[4] / 1e7;
        assertEq(amountIn95, (95e18 * (balanceIn + adjustedSurcharge)).ceilDiv(balanceOut));
        assertEq(amountIn5, (5e18 * (balanceIn + surcharge)).ceilDiv(balanceOut));
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            receiver: address(0),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
            allowZeroAmountIn: true,
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

    function _buildTakerData(bool exactIn) private view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: exactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: true,
            usePermit2: false,
            threshold: "",
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
            signature: ""
        }));
    }
}
