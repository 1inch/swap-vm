// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouterDebug } from "../src/routers/SwapVMRouterDebug.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { DynamicBalances } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { FeeProtocol } from "../src/instructions/FeeProtocol.sol";

import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";

uint256 constant BPS = 1e7;

/// @notice FeeProtocol combinations: multiple receivers, provider + receiver, flat + surplus
contract FeeProtocolCombinationsTest is Test, OpcodesDebug {
    using Math for uint256;

    SwapVMRouterDebug public swapVM;
    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");
    address public receiver1 = makeAddr("receiver1");
    address public receiver2 = makeAddr("receiver2");
    address public providerReceiver = makeAddr("providerReceiver");

    ProtocolFeeProviderMock public feeProvider;

    uint256 constant BALANCE_A = 100e18;
    uint256 constant BALANCE_B = 200e18;

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouterDebug(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = address(new TokenMock("Token I", "TKI"));
        tokenB = address(new TokenMock("Token J", "TKJ"));
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        TokenMock(tokenA).mint(maker, 1000e18);
        TokenMock(tokenB).mint(maker, 1000e18);
        TokenMock(tokenA).mint(taker, 1000e18);
        TokenMock(tokenB).mint(taker, 1000e18);

        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);

        feeProvider = new ProtocolFeeProviderMock(0.01e7, 0, providerReceiver, address(this));
    }

    // ========== Program / order helpers ==========

    function _createOrder(bytes memory feeInstruction) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        bytes memory programBytes = bytes.concat(
            feeInstruction,
            DynamicBalances.build(BALANCE_A, BALANCE_B),
            XYCSwap.build()
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: tokenA,
            tokenB: tokenB,
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
            program: programBytes
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _takerData(bool isExactIn, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
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

    function _receivers2(uint24 bps1, uint24 sBps1, uint24 bps2, uint24 sBps2) internal view returns (FeeProtocol.ReceiverConfig[] memory receivers) {
        receivers = new FeeProtocol.ReceiverConfig[](2);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: receiver1, feeBps: bps1, surplusBps: sBps1 });
        receivers[1] = FeeProtocol.ReceiverConfig({ receiver: receiver2, feeBps: bps2, surplusBps: sBps2 });
    }

    function _receivers1(uint24 feeBps, uint24 surplusBps) internal view returns (FeeProtocol.ReceiverConfig[] memory receivers) {
        receivers = new FeeProtocol.ReceiverConfig[](1);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: receiver1, feeBps: feeBps, surplusBps: surplusBps });
    }

    function _noProviders() internal pure returns (FeeProtocol.ProviderConfig[] memory) {
        return new FeeProtocol.ProviderConfig[](0);
    }

    function _noReceivers() internal pure returns (FeeProtocol.ReceiverConfig[] memory) {
        return new FeeProtocol.ReceiverConfig[](0);
    }

    /// @dev XYC exactIn output for this suite's balances
    function _xycOut(uint256 amountIn) internal pure returns (uint256) {
        return amountIn * BALANCE_B / (BALANCE_A + amountIn);
    }

    // ========== Multiple receivers ==========

    /// @notice Two flat fee-in receivers each get amount * ownBps / BPS; maker receives the remainder
    function test_MultipleReceivers_FeeIn_ExactIn() public {
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(true, _receivers2(0.01e7, 0, 0.005e7, 0), _noProviders(), 0)
        );

        uint256 amountIn = 10e18;
        uint256 makerBalanceBefore = TokenMock(tokenA).balanceOf(maker);

        vm.prank(taker);
        (uint256 actualAmountIn, uint256 amountOut,) = swapVM.swap(order, amountIn, _takerData(true, signature));

        uint256 fee1 = amountIn * 0.01e7 / BPS;
        uint256 fee2 = amountIn * 0.005e7 / BPS;

        assertEq(actualAmountIn, amountIn, "Taker pays exactly the specified amountIn");
        assertEq(TokenMock(tokenA).balanceOf(receiver1), fee1, "Receiver1 flat fee");
        assertEq(TokenMock(tokenA).balanceOf(receiver2), fee2, "Receiver2 flat fee");
        assertEq(TokenMock(tokenA).balanceOf(maker), makerBalanceBefore + amountIn - fee1 - fee2, "Maker receives net of both fees");

        // Curve is priced on the net input (total 1.5%)
        uint256 netIn = amountIn - amountIn * 0.015e7 / BPS;
        assertEq(amountOut, _xycOut(netIn), "Curve priced on net input");
    }

    /// @notice Two flat fee-out receivers split the out-side fee via the totalBps gross-up;
    ///         their fees sum to what the curve over-delivered
    function test_MultipleReceivers_FeeOut_ExactIn() public {
        uint24 totalBps = 0.015e7; // 1% + 0.5%
        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(false, _receivers2(0.01e7, 0, 0.005e7, 0), _noProviders(), 0)
        );

        uint256 amountIn = 10e18;
        uint256 makerBalanceBefore = TokenMock(tokenB).balanceOf(maker);
        uint256 takerBalanceBefore = TokenMock(tokenB).balanceOf(taker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, _takerData(true, signature));

        uint256 grossOut = _xycOut(amountIn);
        uint256 netOut = grossOut - grossOut * totalBps / BPS;
        assertEq(amountOut, netOut, "Taker receives net output");
        assertEq(TokenMock(tokenB).balanceOf(taker), takerBalanceBefore + netOut, "Taker got net output");

        // Per-receiver gross-up uses the TOTAL bps denominator so fees sum to the priced total
        uint256 fee1 = netOut * 0.01e7 / (BPS - totalBps);
        uint256 fee2 = netOut * 0.005e7 / (BPS - totalBps);
        assertEq(TokenMock(tokenB).balanceOf(receiver1), fee1, "Receiver1 out fee");
        assertEq(TokenMock(tokenB).balanceOf(receiver2), fee2, "Receiver2 out fee");

        // Together the receivers get (almost exactly) what the curve over-delivered
        assertApproxEqAbs(fee1 + fee2, grossOut - netOut, 2, "Fees sum to the priced out-side total");

        assertEq(TokenMock(tokenB).balanceOf(maker), makerBalanceBefore - netOut - fee1 - fee2, "Maker pays net plus fees");
    }

    // ========== Provider + receiver ==========

    /// @notice A provider-driven fee and a static receiver fee are charged independently and both paid out
    function test_ProviderPlusReceiver_FeeIn_ExactIn() public {
        feeProvider.setRecipientAndFees(providerReceiver, 0.01e7, 0); // provider: 1% flat

        FeeProtocol.ProviderConfig[] memory providers = new FeeProtocol.ProviderConfig[](1);
        providers[0] = FeeProtocol.ProviderConfig({ provider: address(feeProvider), takeFlatFee: true, takeSurplusFee: false });

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(true, _receivers1(0.005e7, 0), providers, 0)
        );

        uint256 amountIn = 10e18;
        uint256 makerBalanceBefore = TokenMock(tokenA).balanceOf(maker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, _takerData(true, signature));

        uint256 staticFee = amountIn * 0.005e7 / BPS;
        uint256 providerFee = amountIn * 0.01e7 / BPS;

        assertEq(TokenMock(tokenA).balanceOf(receiver1), staticFee, "Static receiver fee");
        assertEq(TokenMock(tokenA).balanceOf(providerReceiver), providerFee, "Provider-designated receiver fee");
        assertEq(TokenMock(tokenA).balanceOf(maker), makerBalanceBefore + amountIn - staticFee - providerFee, "Maker nets both fees");

        uint256 netIn = amountIn - amountIn * 0.015e7 / BPS;
        assertEq(amountOut, _xycOut(netIn), "Curve priced on net of combined fees");
    }

    /// @notice Combined provider + receiver bps above 100% revert at execution
    function test_ProviderPlusReceiver_TotalAboveHundredPercent_Reverts() public {
        feeProvider.setRecipientAndFees(providerReceiver, 0.6e7, 0); // 60%

        FeeProtocol.ProviderConfig[] memory providers = new FeeProtocol.ProviderConfig[](1);
        providers[0] = FeeProtocol.ProviderConfig({ provider: address(feeProvider), takeFlatFee: true, takeSurplusFee: false });

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(true, _receivers1(0.5e7, 0), providers, 0) // + 50%
        );

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(FeeProtocol.FeeBpsOutOfRange.selector, 1.1e7, 0));
        swapVM.swap(order, 10e18, _takerData(true, signature));
    }

    // ========== Flat + surplus ==========

    /// @notice Flat and surplus parts accrue to the same receiver: flat on the gross input,
    ///         surplus on the excess of the real input over the scaled estimate
    function test_FlatPlusSurplus_FeeIn_ExactIn() public {
        uint24 flatBps = 0.01e7;    // 1%
        uint24 surplusBps = 0.1e7;  // 10% of the surplus
        uint216 estimatedIn = 50e18; // estimate: 50 tokenA to consume the whole balanceOut

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(true, _receivers1(flatBps, surplusBps), _noProviders(), estimatedIn)
        );

        uint256 amountIn = 10e18;
        uint256 makerBalanceBefore = TokenMock(tokenA).balanceOf(maker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, _takerData(true, signature));

        // Mirror the contract's surplus math
        uint256 flatFee = amountIn * flatBps / BPS;
        uint256 realIn = amountIn - flatFee;
        uint256 scaledEstimate = (uint256(estimatedIn) * amountOut).ceilDiv(BALANCE_B);
        assertGt(realIn, scaledEstimate, "Sanity: maker received more than estimated");
        uint256 surplus = realIn - scaledEstimate;
        uint256 surplusFee = surplus * surplusBps / BPS;

        assertEq(TokenMock(tokenA).balanceOf(receiver1), flatFee + surplusFee, "Receiver gets flat + surplus");
        assertEq(TokenMock(tokenA).balanceOf(maker), makerBalanceBefore + amountIn - flatFee - surplusFee, "Maker pays the surplus fee out of the excess");
        assertEq(amountOut, _xycOut(realIn), "Curve priced on net of flat fee only");
    }

    /// @notice No surplus fee is charged when the maker underperforms the estimate
    function test_FlatPlusSurplus_FeeIn_NoSurplusBelowEstimate() public {
        uint24 flatBps = 0.01e7;
        uint216 estimatedIn = 1000e18; // estimate far above anything reachable

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(true, _receivers1(flatBps, 0.1e7), _noProviders(), estimatedIn)
        );

        uint256 amountIn = 10e18;

        vm.prank(taker);
        swapVM.swap(order, amountIn, _takerData(true, signature));

        assertEq(TokenMock(tokenA).balanceOf(receiver1), amountIn * flatBps / BPS, "Only the flat part is charged");
    }

    /// @notice Out-side surplus: maker under-delivers vs the estimate, the shortfall is the surplus base
    function test_FlatPlusSurplus_FeeOut_ExactIn() public {
        uint24 flatBps = 0.01e7;    // 1%
        uint24 surplusBps = 0.2e7;  // 20% of the surplus
        uint216 estimatedOut = 400e18; // estimate: 400 tokenB out for the whole balanceIn

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(false, _receivers1(flatBps, surplusBps), _noProviders(), estimatedOut)
        );

        uint256 amountIn = 10e18;
        uint256 makerBalanceBefore = TokenMock(tokenB).balanceOf(maker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, _takerData(true, signature));

        uint256 grossOut = _xycOut(amountIn);
        uint256 netOut = grossOut - grossOut * flatBps / BPS;
        assertEq(amountOut, netOut, "Taker receives net output");

        // Mirror the contract's surplus math
        uint256 totalFeeMax = netOut * flatBps / (BPS - flatBps);
        uint256 realOut = netOut + totalFeeMax;
        uint256 scaledEstimate = uint256(estimatedOut) * amountIn / BALANCE_A;
        assertGt(scaledEstimate, realOut, "Sanity: maker delivered less than estimated");
        uint256 surplus = scaledEstimate - realOut;

        uint256 expectedFee = netOut * flatBps / (BPS - flatBps) + surplus * surplusBps / BPS;
        assertEq(TokenMock(tokenB).balanceOf(receiver1), expectedFee, "Receiver gets flat + surplus in tokenOut");
        assertEq(TokenMock(tokenB).balanceOf(maker), makerBalanceBefore - netOut - expectedFee, "Maker pays output, flat and surplus");
    }

    /// @notice Flat-only and surplus-only receivers coexist: each is paid only its own component
    function test_SplitRoles_FlatReceiverPlusSurplusReceiver_FeeIn() public {
        uint24 flatBps = 0.01e7;
        uint24 surplusBps = 0.1e7;
        uint216 estimatedIn = 50e18;

        (ISwapVM.Order memory order, bytes memory signature) = _createOrder(
            FeeProtocol.build(true, _receivers2(flatBps, 0, 0, surplusBps), _noProviders(), estimatedIn)
        );

        uint256 amountIn = 10e18;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, amountIn, _takerData(true, signature));

        uint256 flatFee = amountIn * flatBps / BPS;
        uint256 realIn = amountIn - flatFee;
        uint256 scaledEstimate = (uint256(estimatedIn) * amountOut).ceilDiv(BALANCE_B);
        uint256 surplusFee = (realIn - scaledEstimate) * surplusBps / BPS;

        assertEq(TokenMock(tokenA).balanceOf(receiver1), flatFee, "Flat-only receiver gets only the flat part");
        assertEq(TokenMock(tokenA).balanceOf(receiver2), surplusFee, "Surplus-only receiver gets only the surplus part");
    }
}
