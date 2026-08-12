// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { SwapRegisters } from "../src/libs/VM.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { PatchSwapRegisters } from "../src/instructions/Debug.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";

contract FeeProtocolCommissionsTest is Test {
    uint256 constant BPS = 1e7;
    uint256 constant MAX_RECEIVERS = 10;

    SwapVMRouterDebug public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address[MAX_RECEIVERS] public recipients;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouterDebug(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e60);
        tokenB.mint(maker, 1e60);
        tokenA.mint(taker, 1e60);
        tokenB.mint(taker, 1e60);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);

        for (uint256 i = 0; i < MAX_RECEIVERS; i++) {
            recipients[i] = makeAddr(string.concat("recipient", vm.toString(i)));
        }
    }

    function testFuzz_Commissions_TokenIn_ExactIn(uint256 amount, uint256 amountPartial, uint256 count, uint24[10] memory fees, bool mode) public {
        amount = bound(amount, 1, mode ? 1e50 : 100);
        count = bound(count, 1, MAX_RECEIVERS);
        uint24 totalBps = _boundFees(count, fees);

        // Fee is carved from the taker amount pre-loop: the loop drifts the net input down
        uint256 fee = amount * totalBps / BPS;
        amountPartial = bound(amountPartial, 0, amount - fee);
        bool isPartialFill = amountPartial != amount - fee;

        ISwapVM.Order memory order = _order(true, count, fees, amountPartial, 1e18);

        uint256 takerBefore = tokenA.balanceOf(taker);
        uint256 makerBefore = tokenA.balanceOf(maker);
        uint256[] memory recipientsBefore = _recipientBalances(tokenA, count);

        (uint256 realIn,,) = swapVM.swap(order, amount, _makeTakerData(order, true));

        uint256 realFee = realIn - amountPartial;
        // No partial fill -> no taker-specified amount drift
        if (!isPartialFill) {
            assertEq(realIn, amount, "Exact fill should keep the taker amountIn");
            assertEq(realFee, fee, "Exact fill should keep fee");
        }

        // Paid commissions <= predicted by the opcode (its amountIn register delta), drift down capped by receivers - 1
        uint256 paid = _recipientsReceived(tokenA, count, recipientsBefore);
        assertLe(paid, realFee, "Paid commissions should not exceed the prediction");
        assertLe(realFee - paid, count - 1, "Commission rounding drift should be below the receivers count");

        // Taker pays exactly the swap input, maker receives it minus the commissions
        assertEq(takerBefore - tokenA.balanceOf(taker), realIn);
        assertEq(tokenA.balanceOf(maker) - makerBefore, realIn - paid, "Rounding dust should stay with the maker");
    }

    function testFuzz_Commissions_TokenIn_ExactOut(uint256 amount, uint256 amountPartial, uint256 amountIn, uint256 count, uint24[10] memory fees, bool mode) public {
        amount = bound(amount, 1, mode ? 1e50 : 100);
        count = bound(count, 1, MAX_RECEIVERS);
        uint24 totalBps = _boundFees(count, fees);

        // Fee is added post-loop on top of the input computed by the loop: the loop drifts the output down
        amountPartial = bound(amountPartial, 1, amount);
        bool isPartialFill = amountPartial != amount;
        amountIn = bound(amountIn, 0, mode ? 1e50 : 100);

        ISwapVM.Order memory order = _order(true, count, fees, amountIn, amountPartial);

        uint256 takerBefore = tokenA.balanceOf(taker);
        uint256 makerBefore = tokenA.balanceOf(maker);
        uint256[] memory recipientsBefore = _recipientBalances(tokenA, count);

        (uint256 realIn, uint256 realOut,) = swapVM.swap(order, amount, _makeTakerData(order, false));

        uint256 realFee = realIn - amountIn;
        // No partial fill -> no taker-specified amount drift
        if (!isPartialFill) assertEq(realOut, amount, "Exact fill should keep the taker amountIn");

        // Paid commissions <= predicted by the opcode (its amountIn register delta), drift down capped by receivers - 1
        uint256 paid = _recipientsReceived(tokenA, count, recipientsBefore);
        assertLe(paid, realFee, "Paid commissions should not exceed the prediction");
        assertLe(realFee - paid, count - 1, "Commission rounding drift should be below the receivers count");

        // Taker pays exactly the swap input, maker receives it minus the commissions
        assertEq(takerBefore - tokenA.balanceOf(taker), realIn);
        assertEq(tokenA.balanceOf(maker) - makerBefore, realIn - paid, "Rounding dust should stay with the maker");
    }

    function testFuzz_Commissions_TokenOut_ExactIn(uint256 amount, uint256 amountPartial, uint256 amountOut, uint256 count, uint24[10] memory fees, bool mode) public {
        amount = bound(amount, 1, mode ? 1e50 : 100);
        count = bound(count, 1, MAX_RECEIVERS);
        uint24 totalBps = _boundFees(count, fees);

        // Fee is deducted post-loop from the output computed by the loop: the loop drifts the input down
        amountPartial = bound(amountPartial, 0, amount);
        bool isPartialFill = amountPartial != amount;
        amountOut = bound(amountOut, 0, mode ? 1e50 : 100);

        ISwapVM.Order memory order = _order(false, count, fees, amountPartial, amountOut);

        uint256 takerBefore = tokenB.balanceOf(taker);
        uint256 makerBefore = tokenB.balanceOf(maker);
        uint256[] memory recipientsBefore = _recipientBalances(tokenB, count);

        uint256 realIn;
        uint256 realOut;
        try swapVM.swap(order, amount, _makeTakerData(order, true)) returns (uint256 amountIn, uint256 amountOut, bytes32) {
            (realIn, realOut) = (amountIn, amountOut);
        } catch (bytes memory reason) {
            // Only dust fills deducted to zero output may revert
            assertEq(bytes4(reason), TakerTraitsLib.TakerTraitsAmountOutMustBeGreaterThanZero.selector);
            assertEq(amountOut - amountOut * totalBps / BPS, 0);
            return;
        }

        uint256 realFee = amountOut - realOut;

        // No partial fill -> no taker-specified amount drift
        if (!isPartialFill) assertEq(realIn, amount, "Exact fill should keep the taker amountIn");

        // Paid commissions <= predicted by the opcode (its amountOut register delta), drift down capped by receivers - 1
        uint256 paid = _recipientsReceived(tokenB, count, recipientsBefore);
        assertLe(paid, realFee, "Paid commissions should not exceed the prediction");
        assertLe(realFee - paid, count - 1, "Commission rounding drift should be below the receivers count");

        // Taker receives exactly the swap output, maker pays it plus the commissions
        assertEq(tokenB.balanceOf(taker) - takerBefore, realOut);
        assertEq(makerBefore - tokenB.balanceOf(maker), realOut + paid, "Maker pays the output and the commissions");
    }

    function testFuzz_Commissions_TokenOut_ExactOut(uint256 amount, uint256 amountPartial, uint256 count, uint24[10] memory fees, bool mode) public {
        amount = bound(amount, 1, mode ? 1e50 : 100);
        count = bound(count, 1, MAX_RECEIVERS);
        uint24 totalBps = _boundFees(count, fees);

        // Fee is added to the taker amount pre-loop: the loop drifts the gross output down
        uint256 fee = amount * totalBps / (BPS - totalBps);
        amountPartial = bound(amountPartial, 1, amount + fee);
        bool isPartialFill = amountPartial != amount + fee;

        ISwapVM.Order memory order = _order(false, count, fees, 1e18, amountPartial);

        uint256 takerBefore = tokenB.balanceOf(taker);
        uint256 makerBefore = tokenB.balanceOf(maker);
        uint256[] memory recipientsBefore = _recipientBalances(tokenB, count);

        (, uint256 realOut,) = swapVM.swap(order, amount, _makeTakerData(order, false));

        uint256 realFee = amountPartial - realOut;
        // No partial fill -> no taker-specified amount drift
        if (!isPartialFill) {
            assertEq(realOut, amount, "Exact fill should keep the taker amountOut");
            assertEq(realFee, fee, "Exact fill should keep fee");
        }

        // Paid commissions <= predicted by the opcode (its amountOut register delta), drift down capped by receivers - 1
        uint256 paid = _recipientsReceived(tokenB, count, recipientsBefore);
        assertLe(paid, realFee, "Paid commissions should not exceed the prediction");
        assertLe(realFee - paid, count - 1, "Commission rounding drift should be below the receivers count");

        // Taker receives exactly the swap output, maker pays it plus the commissions
        assertEq(tokenB.balanceOf(taker) - takerBefore, realOut);
        assertEq(makerBefore - tokenB.balanceOf(maker), realOut + paid, "Maker pays the output and the commissions");
    }

    // === Helpers ===

    function _order(bool isTokenIn, uint256 count, uint24[10] memory fees, uint256 amountIn, uint256 amountOut) internal view returns (ISwapVM.Order memory) {
        return _createOrder(bytes.concat(
            _feeProtocolProgram(isTokenIn, count, fees),
            PatchSwapRegisters.build(SwapRegisters({ balanceIn: 0, balanceOut: 0, amountIn: amountIn, amountOut: amountOut }))
        ));
    }

    /// @dev Distributes up to BPS - 1 total across the receivers: each fee takes a fuzzed share
    ///   of the remaining budget, reserving 1 for every receiver still to come. Covers the whole
    ///   simplex including skewed splits, e.g. one receiver near 100% next to dust receivers.
    function _boundFees(uint256 count, uint24[10] memory fees) internal pure returns (uint24 totalBps) {
        uint256 budget = BPS - 1;
        for (uint256 i = 0; i < count; i++) {
            fees[i] = uint24(bound(fees[i], 1, budget - (count - i - 1)));
            budget -= fees[i];
            totalBps += fees[i];
        }
    }

    function _feeProtocolProgram(bool isTokenIn, uint256 count, uint24[10] memory fees) internal view returns (bytes memory) {
        FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            receivers[i] = FeeProtocol.ReceiverConfig({ receiver: recipients[i], feeBps: fees[i], surplusBps: 0 });
        }
        return FeeProtocol.build(isTokenIn, receivers, new FeeProtocol.ProviderConfig[](0), 0);
    }

    function _recipientBalances(TokenMock token, uint256 count) internal view returns (uint256[] memory balances) {
        balances = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            balances[i] = token.balanceOf(recipients[i]);
        }
    }

    function _recipientsReceived(TokenMock token, uint256 count, uint256[] memory balancesBefore) internal view returns (uint256 paid) {
        for (uint256 i = 0; i < count; i++) {
            paid += token.balanceOf(recipients[i]) - balancesBefore[i];
        }
    }

    function _createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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

    function _makeTakerData(ISwapVM.Order memory order, bool isExactIn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: true,
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
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
