// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { EthReceiver } from "@1inch/solidity-utils/contracts/mixins/EthReceiver.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { OrderRegistrator } from "../../contracts/extensions/OrderRegistrator.sol";
import { MakerTraits, MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { Deadline, Salt } from "../../contracts/instructions/Controls.sol";
import { InvalidateTokenOut } from "../../contracts/instructions/Invalidators.sol";
import { NativeOrder, NativeOrderLib } from "../../contracts/extensions/nativeorder/NativeOrderLib.sol";
import { NativeOrderEscrow } from "../../contracts/extensions/nativeorder/NativeOrderEscrow.sol";
import { NativeOrderFactory } from "../../contracts/extensions/nativeorder/NativeOrderFactory.sol";
import { SwapVMRouter, TraitsHelper, DeployCode } from "./helpers/SwapVMTestSetup.sol";
import { WETHMock } from "./mocks/WETHMock.sol";
import { MockMakerHooks } from "./mocks/MockMakerHooks.sol";
import { NativeOrderReceiver } from "./mocks/NativeOrderReceiver.sol";

contract NativeOrderEscrowTest is Test {
    uint256 private constant WETH_AMOUNT = 1 ether;
    uint256 private constant DAI_AMOUNT = 3000e18;
    uint40 private constant EXPIRY_OFFSET = 1 days;
    uint32 private constant PUBLIC_CANCEL_DELAY = 1 hours;
    uint56 private constant MAX_BASE_FEE = 10 gwei;
    uint256 private constant CANCEL_GAS_REFUND = 70_000;
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

    SwapVMRouter public router;
    TraitsHelper internal orders;
    WETHMock public weth;
    TokenMock public dai;
    TokenMock public accessToken;
    NativeOrderFactory public factory;
    address public maker;
    address public resolver;
    bool public isAToB;

    ISwapVM.Order internal makerOrder;
    ISwapVM.Order internal filledOrder;
    NativeOrder internal nativeOrder;
    NativeOrderEscrow internal escrow;
    bytes32 internal filledOrderHash;

    function setUp() public {
        weth = new WETHMock();
        dai = new TokenMock("DAI", "DAI");
        accessToken = new TokenMock("Resolver Access", "RAT");
        orders = DeployCode.TraitsHelper();
        router = DeployCode.SwapVMRouter(address(0), address(weth), address(this), "SwapVM", "1.0.0");
        factory = new NativeOrderFactory(
            address(router),
            IWETH(address(weth)),
            IERC20(address(accessToken)),
            CANCEL_GAS_REFUND,
            uint24(PUBLIC_CANCEL_DELAY)
        );
        maker = makeAddr("maker");
        resolver = makeAddr("resolver");
        vm.deal(maker, 100 ether);
        vm.deal(address(this), 100 ether);
        accessToken.mint(resolver, 1);
        dai.mint(address(this), 1e30);
        dai.approve(address(router), type(uint256).max);
        isAToB = address(dai) < address(weth);
    }

    // Fills and quotes.

    function test_NativeOrder_FullFill_ExactOut() public {
        _createEscrow(_defaultProgram());
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
        assertEq(address(escrow).balance, 0);
        (uint256 amountIn, uint256 amountOut,) = router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(amountIn, DAI_AMOUNT);
        assertEq(amountOut, WETH_AMOUNT);
        assertEq(weth.balanceOf(address(this)), WETH_AMOUNT);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(dai.balanceOf(address(escrow)), 0);
        assertEq(weth.allowance(address(escrow), address(router)), 0);
    }

    function test_NativeOrder_FullFill_ExactIn() public {
        _createEscrow(_defaultProgram());
        (uint256 amountIn, uint256 amountOut,) = router.swap(filledOrder, DAI_AMOUNT, _takerData(true));
        assertEq(amountIn, DAI_AMOUNT);
        assertEq(amountOut, WETH_AMOUNT);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
        assertEq(weth.balanceOf(address(this)), WETH_AMOUNT);
    }

    function test_NativeOrder_FullFill_TakerReceivesNativeEth() public {
        _createEscrow(_defaultProgram());
        TraitsHelper.TakerTraitsLibArgs memory args;
        args.isAToB = isAToB;
        args.shouldUnwrapWeth = true;
        args.signature = _signature();
        uint256 ethBefore = address(this).balance;
        router.swap(filledOrder, WETH_AMOUNT, orders.TakerTraitsLibBuild(args));
        assertEq(address(this).balance - ethBefore, WETH_AMOUNT);
        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
    }

    function test_NativeOrder_PartialFills_ThenCancelRemainder() public {
        _createEscrow(_defaultProgram());
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        router.swap(filledOrder, 0.35 ether, _takerData(false));
        assertEq(weth.balanceOf(address(this)), 0.75 ether);
        assertEq(weth.balanceOf(address(escrow)), 0.25 ether);
        assertEq(weth.allowance(address(escrow), address(router)), 0.25 ether);
        assertEq(dai.balanceOf(maker), 2250e18);
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.25 ether);
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(weth.allowance(address(escrow), address(router)), 0.25 ether);
    }

    function test_NativeOrder_ExplicitReceiverReceivesProceedsButMakerOwnsRefund() public {
        address recipient = makeAddr("recipient");
        TraitsHelper.MakerTraitsLibArgs memory args = _orderArgs(_defaultProgram());
        args.receiver = recipient;
        _createOrder(orders.MakerTraitsLibBuild(args), WETH_AMOUNT, _expiration());
        router.swap(filledOrder, 0.4 ether, _takerData(false));

        assertEq(dai.balanceOf(recipient), 1200e18);
        assertEq(dai.balanceOf(maker), 0);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(NativeOrderEscrow.NotMaker.selector, recipient, maker));
        escrow.cancel(nativeOrder);

        uint256 makerBefore = maker.balance;
        uint256 recipientBefore = recipient.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.6 ether);
        assertEq(recipient.balance, recipientBefore);
        assertEq(dai.balanceOf(recipient), 1200e18);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_Quote_BeforeAndAfterPartialFill() public {
        _createEscrow(_defaultProgram());
        (uint256 amountIn, uint256 amountOut,) = router.asView().quote(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(amountIn, DAI_AMOUNT);
        assertEq(amountOut, WETH_AMOUNT);
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        (amountIn, amountOut,) = router.asView().quote(filledOrder, 0.6 ether, _takerData(false));
        assertEq(amountIn, 1800e18);
        assertEq(amountOut, 0.6 ether);
    }

    function test_NativeOrder_Fill_AfterProgramDeadline() public {
        uint40 deadline = uint40(block.timestamp + EXPIRY_OFFSET / 2);
        _createEscrow(_program(deadline));
        vm.warp(deadline + 1);
        bytes memory takerData = _takerData(false);
        vm.expectRevert(abi.encodeWithSelector(Deadline.DeadlineReached.selector, deadline));
        router.swap(filledOrder, WETH_AMOUNT, takerData);
    }

    function test_NativeOrder_Fill_ExpirationInvalidatesSignatureBeforeProgramDeadline() public {
        _createEscrow(_program(uint40(block.timestamp + 2 * EXPIRY_OFFSET)));
        bytes memory signature = _signature();
        bytes memory takerData = _takerData(false, signature);
        vm.warp(_orderExpiration() - 1);
        assertEq(escrow.isValidSignature(filledOrderHash, signature), ERC1271_MAGIC);
        router.swap(filledOrder, 0.5 ether, takerData);
        vm.warp(_orderExpiration());
        assertEq(escrow.isValidSignature(filledOrderHash, signature), bytes4(0));
        _expectBadSignature(signature);
        router.swap(filledOrder, 0.5 ether, takerData);
    }

    function test_NativeOrder_DepositAndApprove_OnlyFactory() public {
        _createEscrow(_defaultProgram());
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(NativeOrderEscrow.NotFactory.selector, maker, address(factory)));
        escrow.depositAndApprove{ value: 1 ether }();
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    // Maker cancellation withdraws the current balance without revoking the order.

    function test_NativeOrder_Cancel_RefundsCurrentBalanceAndOrderCanBeFundedAgain() public {
        _createEscrow(_defaultProgram());
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
        assertTrue(_quoteSucceeds());

        _donateWeth(WETH_AMOUNT);
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
    }

    function test_NativeOrder_Cancel_OnlyMaker() public {
        _createEscrow(_defaultProgram());
        vm.expectRevert(abi.encodeWithSelector(NativeOrderEscrow.NotMaker.selector, address(this), maker));
        escrow.cancel(nativeOrder);
    }

    function test_NativeOrder_Cancel_EmptyBalanceRevertsAndLaterDonationCanBeWithdrawn() public {
        _createEscrow(_defaultProgram());
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrow.CancelForZeroBalance.selector);
        escrow.cancel(nativeOrder);
        _donateWeth(0.3 ether);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.3 ether);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_FullFill_DonationCannotReviveAndResolverCanClean() public {
        _createEscrow(_defaultProgram());
        bytes memory takerData = _takerData(false);
        router.swap(filledOrder, WETH_AMOUNT, takerData);
        _donateWeth(0.3 ether);
        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        router.swap(filledOrder, 0.1 ether, takerData);
        vm.warp(_rewardCancelStart());
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(weth.allowance(address(escrow), address(router)), 0);
    }

    function test_NativeOrder_Cancel_LeavesForcedEthForExplicitRescue() public {
        _createEscrow(_defaultProgram());
        vm.deal(address(escrow), 0.7 ether);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
        assertEq(address(escrow).balance, 0.7 ether);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, IERC20(address(0)), 0.7 ether);
        assertEq(maker.balance - makerBefore, 1.7 ether);
        assertEq(address(escrow).balance, 0);
    }

    function test_NativeOrder_DirectEthTransferIsRejected() public {
        _createEscrow(_defaultProgram());
        (bool success, bytes memory reason) = address(escrow).call{ value: 1 }("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(EthReceiver.EthDepositRejected.selector));
        assertEq(address(escrow).balance, 0);
    }

    // Resolver access, timing, reward accounting and repeat cleanup.

    function test_NativeOrder_CancelExpired_TimeAndAccessGates() public {
        _createEscrow(_defaultProgram());
        uint256 expiration = _orderExpiration();
        vm.warp(expiration - 1);
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.NotExpired.selector, expiration - 1, expiration)
        );
        escrow.cancelExpired(nativeOrder);
        vm.warp(expiration);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.NotResolver.selector, address(this), address(accessToken))
        );
        escrow.cancelExpired(nativeOrder);
        // Eligibility is checked at cancellation, rather than snapshotted at creation.
        vm.prank(resolver);
        accessToken.transfer(address(this), 1);
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.NotResolver.selector, resolver, address(accessToken))
        );
        escrow.cancelExpired(nativeOrder);
        accessToken.transfer(resolver, 1);
        vm.prank(resolver);
        escrow.cancelExpired(nativeOrder);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_ForcedEthIsNotDistributed() public {
        _createEscrow(_defaultProgram());
        vm.warp(_rewardCancelStart());
        vm.fee(MAX_BASE_FEE);
        vm.deal(address(escrow), 2 ether);
        uint256 reward = uint256(MAX_BASE_FEE) * CANCEL_GAS_REFUND;
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, reward);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT - reward);
        assertEq(address(escrow).balance, 2 ether);
    }

    function test_NativeOrder_CancelExpiredForReward_CappedByMaxBaseFee() public {
        uint56 maxBaseFee = 2 gwei;
        vm.fee(10 gwei);
        _createOrder(_buildOrder(_defaultProgram()), WETH_AMOUNT, _expiration(), maxBaseFee);
        vm.warp(_rewardCancelStart());
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        uint256 reward = uint256(maxBaseFee) * CANCEL_GAS_REFUND;
        assertEq(resolver.balance, reward);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT - reward);

        // A zero max base fee offers no reward.
        _createOrder(_buildOrder(_defaultProgram()), WETH_AMOUNT, _expiration(), 0);
        vm.warp(_rewardCancelStart());
        makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, reward);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
    }

    function test_NativeOrder_CancelExpiredForReward_TamperedMaxBaseFeeIsDifferentOrder() public {
        _createEscrow(_defaultProgram());
        vm.warp(_rewardCancelStart());
        NativeOrder memory tampered = _tamper(4, 0);
        address tamperedEscrow = factory.addressOfEscrow(tampered);
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.BadOrder.selector, tamperedEscrow, address(escrow))
        );
        escrow.cancelExpiredForReward(tampered);
        assertEq(resolver.balance, 0);
        _assertCancellationRolledBack();
    }

    function test_NativeOrder_CancelExpiredForReward_UsesLiveBalanceIncludingDonations() public {
        vm.fee(type(uint56).max);
        _createOrder(_buildOrder(_defaultProgram()), WETH_AMOUNT, _expiration(), type(uint56).max);
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        _donateWeth(2 ether);
        vm.warp(_rewardCancelStart());
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, 2.6 ether);
        assertEq(maker.balance, makerBefore);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_RewardCappedByLiveWethBalance() public {
        _createEscrow(_defaultProgram());
        // Model a token balance deficit without changing the escrow's allowance.
        vm.prank(address(escrow));
        weth.transfer(address(this), WETH_AMOUNT - 123);
        vm.fee(type(uint56).max);
        vm.warp(_rewardCancelStart());
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, 123);
        assertEq(maker.balance, makerBefore);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_DustRemainder() public {
        _createOrder(_buildOrder(_defaultProgram()), 1, _expiration());
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, 1);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_CanCleanLaterDonation() public {
        _createEscrow(_defaultProgram());
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        uint256 resolverBefore = resolver.balance;
        _donateWeth(WETH_AMOUNT);
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance - resolverBefore, uint256(MAX_BASE_FEE) * CANCEL_GAS_REFUND);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function testFuzz_NativeOrder_CancelExpiredForReward_ConservesFunds(
        uint96 deposit,
        uint56 maxBaseFee,
        uint56 baseFee
    ) public {
        deposit = uint96(bound(deposit, 1, 10 ether));
        baseFee = uint56(bound(baseFee, 0, 100 gwei));
        vm.fee(baseFee);
        _createOrder(_buildOrder(_defaultProgram()), deposit, _expiration(), maxBaseFee);
        vm.warp(_rewardCancelStart());
        uint256 reward = Math.min(uint256(baseFee), uint256(maxBaseFee)) * CANCEL_GAS_REFUND;
        reward = Math.min(reward, deposit);
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, reward);
        assertEq(maker.balance - makerBefore, deposit - reward);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    // ERC-1271 commits to every term through the escrow's CREATE2 address.

    function test_NativeOrder_IsValidSignature_AcceptsCommittedOrder() public {
        _createEscrow(_defaultProgram());
        assertEq(_signature().length, NativeOrderLib.SIZE);
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
    }

    function test_NativeOrder_IsValidSignature_WrongHash() public {
        _createEscrow(_defaultProgram());
        assertEq(escrow.isValidSignature(bytes32(uint256(1)), _signature()), bytes4(0));
    }

    function test_NativeOrder_IsValidSignature_AllCommittedFieldsAreAuthenticated() public {
        _createEscrow(_defaultProgram());
        for (uint8 field = 0; field < 5; ++field) _assertInvalidOrder(_tamper(field, 0));
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
    }

    function testFuzz_NativeOrder_IsValidSignature_TamperedCommitment(uint8 field, uint256 bit) public {
        _createEscrow(_defaultProgram());
        _assertInvalidOrder(_tamper(uint8(bound(field, 0, 4)), bit));
    }

    function testFuzz_NativeOrder_IsValidSignature_MalformedLength(uint16 length) public {
        _createEscrow(_defaultProgram());
        length = uint16(bound(length, 0, 512));
        if (length == NativeOrderLib.SIZE) ++length;
        assertEq(escrow.isValidSignature(filledOrderHash, new bytes(length)), bytes4(0));
    }

    function test_NativeOrder_IsValidSignature_TrailingDataRejected() public {
        _createEscrow(_defaultProgram());
        assertEq(escrow.isValidSignature(filledOrderHash, bytes.concat(_signature(), hex"00")), bytes4(0));
    }

    function testFuzz_NativeOrder_EncodeAndGetters(
        address orderMaker,
        uint256 traits,
        bytes32 dataHash,
        uint40 expiration,
        uint56 maxBaseFee
    ) public {
        NativeOrder memory order =
            NativeOrderLib.encode(orderMaker, MakerTraits.wrap(traits), dataHash, expiration, maxBaseFee);
        this.assertNativeOrderGetters(order, orderMaker, traits, dataHash, expiration, maxBaseFee);
    }

    function testFuzz_NativeOrder_EncodeAbiEncodeWrapAndGetters(
        address orderMaker,
        uint256 traits,
        bytes32 dataHash,
        uint40 expiration,
        uint56 maxBaseFee
    ) public {
        NativeOrder memory order =
            NativeOrderLib.encode(orderMaker, MakerTraits.wrap(traits), dataHash, expiration, maxBaseFee);
        bytes memory signature = abi.encode(order);
        assertEq(signature.length, NativeOrderLib.SIZE);
        assertEq(order.saltMemory(), keccak256(signature));
        this.assertWrappedNativeOrderGetters(signature, orderMaker, traits, dataHash, expiration, maxBaseFee);
    }

    function test_NativeOrder_Swap_TamperedSignatureRevertsBadSignature() public {
        _createEscrow(_defaultProgram());
        bytes memory signature = abi.encode(_tamper(3, 0));
        bytes memory takerData = _takerData(false, signature);
        _expectBadSignature(signature);
        router.swap(filledOrder, WETH_AMOUNT, takerData);
    }

    function test_NativeOrder_IsValidSignature_ProgramAndTraitsCannotBeReplaced() public {
        _createEscrow(_defaultProgram());
        ISwapVM.Order memory attackerOrder = filledOrder;
        attackerOrder.data = bytes.concat(attackerOrder.data, Salt.build(uint64(1)));
        assertEq(escrow.isValidSignature(router.hash(attackerOrder), _signature()), bytes4(0));
        attackerOrder = filledOrder;
        attackerOrder.traits = MakerTraits.wrap(MakerTraits.unwrap(attackerOrder.traits) ^ 1);
        assertEq(escrow.isValidSignature(router.hash(attackerOrder), _signature()), bytes4(0));
    }

    // Factory guards against configurations changed by replacing maker with the escrow.

    function test_NativeOrder_Create_AllowsZeroDepositAndCommitsCallerAsMaker() public {
        ISwapVM.Order memory order = _buildOrder(_defaultProgram());
        bytes32 dataHash = keccak256(order.data);
        vm.prank(maker);
        address zeroEscrow = factory.create(order.traits, dataHash, _expiration(), MAX_BASE_FEE);
        assertEq(weth.balanceOf(zeroEscrow), 0);

        vm.deal(resolver, WETH_AMOUNT);
        uint40 expiration = _expiration();
        NativeOrder memory terms =
            NativeOrderLib.encode(resolver, order.traits, dataHash, expiration, MAX_BASE_FEE);
        vm.prank(resolver);
        address resolverEscrow =
            factory.create{ value: WETH_AMOUNT }(order.traits, dataHash, expiration, MAX_BASE_FEE);
        assertEq(factory.addressOfEscrow(terms), resolverEscrow);
    }

    function test_NativeOrder_Create_AquaRejected() public {
        TraitsHelper.MakerTraitsLibArgs memory args = _orderArgs(_defaultProgram());
        args.useAquaInsteadOfSignature = true;
        ISwapVM.Order memory order = orders.MakerTraitsLibBuild(args);
        vm.prank(maker);
        vm.expectRevert(NativeOrderFactory.NativeOrderUnsupportedFeatures.selector);
        factory.create{ value: WETH_AMOUNT }(
            order.traits, keccak256(order.data), _expiration(), MAX_BASE_FEE
        );
    }

    function test_NativeOrder_Create_ExplicitReceiverRequired() public {
        TraitsHelper.MakerTraitsLibArgs memory args = _orderArgs(_defaultProgram());
        args.receiver = address(0);
        ISwapVM.Order memory order = orders.MakerTraitsLibBuild(args);
        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderFactory.OrderReceiverShouldBeValid.selector, address(0))
        );
        factory.create{ value: WETH_AMOUNT }(
            order.traits, keccak256(order.data), _expiration(), MAX_BASE_FEE
        );
        args.receiver = address(factory);
        order = orders.MakerTraitsLibBuild(args);
        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderFactory.OrderReceiverShouldBeValid.selector, address(factory))
        );
        factory.create{ value: WETH_AMOUNT }(
            order.traits, keccak256(order.data), _expiration(), MAX_BASE_FEE
        );
    }

    function test_NativeOrder_Create_CommitsDataHashWithoutInspectingProgram() public {
        ISwapVM.Order memory order = _buildOrder(_defaultProgram());
        order.data = abi.encodePacked(address(1), address(2));
        _createOrder(order, WETH_AMOUNT, _expiration());
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
    }

    function test_NativeOrder_Create_ElapsedExpirationCanBeCancelledImmediately() public {
        ISwapVM.Order memory order = _buildOrder(_defaultProgram());
        _createOrder(order, WETH_AMOUNT, uint40(block.timestamp));
        vm.prank(resolver);
        escrow.cancelExpired(nativeOrder);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_Create_ImplicitHooksAreFactoryAgnostic() public {
        for (uint8 stage = 0; stage < 4; ++stage) {
            MakerTraitsLib.Args memory args = _hookOrderArgs(_defaultProgram());
            if (stage == 0) args.hasPreTransferInHook = true;
            else if (stage == 1) args.hasPostTransferInHook = true;
            else if (stage == 2) args.hasPreTransferOutHook = true;
            else args.hasPostTransferOutHook = true;
            ISwapVM.Order memory order = MakerTraitsLib.build(args);
            vm.prank(maker);
            address clone = factory.create{ value: WETH_AMOUNT }(
                order.traits, keccak256(order.data), _expiration(), MAX_BASE_FEE
            );
            assertEq(weth.balanceOf(clone), WETH_AMOUNT);
        }
        assertEq(address(factory).balance, 0);
    }

    function test_NativeOrder_Create_ExplicitHooksExecuteForEveryStage() public {
        MockMakerHooks hooks = new MockMakerHooks();
        MakerTraitsLib.Args memory args = _hookOrderArgs(_defaultProgram());
        args.hasPreTransferInHook = true;
        args.hasPostTransferInHook = true;
        args.hasPreTransferOutHook = true;
        args.hasPostTransferOutHook = true;
        args.preTransferInTarget = address(hooks);
        args.postTransferInTarget = address(hooks);
        args.preTransferOutTarget = address(hooks);
        args.postTransferOutTarget = address(hooks);
        args.preTransferInData = hex"01";
        args.postTransferInData = hex"02";
        args.preTransferOutData = hex"03";
        args.postTransferOutData = hex"04";
        _createOrder(MakerTraitsLib.build(args), WETH_AMOUNT, _expiration());
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(hooks.preTransferInCallCount(), 1);
        assertEq(hooks.postTransferInCallCount(), 1);
        assertEq(hooks.preTransferOutCallCount(), 1);
        assertEq(hooks.postTransferOutCallCount(), 1);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
    }

    function test_NativeOrder_Create_DuplicateRejectedAndDifferentDataCreatesDifferentEscrow() public {
        _createEscrow(_defaultProgram());
        address first = address(escrow);
        vm.prank(maker);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.create{ value: WETH_AMOUNT }(
            makerOrder.traits, keccak256(makerOrder.data), _expiration(), MAX_BASE_FEE
        );
        _createEscrow(bytes.concat(Salt.build(uint64(1)), _defaultProgram()));
        assertTrue(address(escrow) != first);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    function test_NativeOrder_Create_AddressHashAndTermsConsistency() public {
        uint256 createdAt = block.timestamp;
        _createEscrow(_defaultProgram());
        assertEq(factory.addressOfEscrow(nativeOrder), address(escrow));
        assertEq(router.hash(filledOrder), filledOrderHash);
        this.assertNativeOrderGetters(
            nativeOrder,
            maker,
            MakerTraits.unwrap(makerOrder.traits),
            keccak256(makerOrder.data),
            uint40(createdAt + EXPIRY_OFFSET),
            MAX_BASE_FEE
        );
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertTrue(factory.IMPLEMENTATION() != address(0));
    }

    // Chain changes re-domain the order hash on both router and escrow.

    function test_NativeOrder_ChainIdChange_AfterCreationUsesNewDomain() public {
        _createEscrow(_defaultProgram());
        bytes32 oldHash = filledOrderHash;
        vm.chainId(block.chainid + 1);
        filledOrderHash = router.hash(filledOrder);
        assertTrue(filledOrderHash != oldHash);
        assertEq(factory.addressOfEscrow(nativeOrder), address(escrow));
        assertEq(escrow.isValidSignature(oldHash, _signature()), bytes4(0));
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        assertEq(weth.balanceOf(address(escrow)), 0.6 ether);
    }

    function test_NativeOrder_ChainIdChange_AfterCreationRescueStillWorks() public {
        _createEscrow(_defaultProgram());
        dai.mint(address(escrow), 123e18);
        vm.chainId(block.chainid + 1);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, IERC20(address(dai)), 123e18);
        assertEq(dai.balanceOf(maker), 123e18);
    }

    // Maker recovery is available at any time and does not revoke the order.

    function test_NativeOrder_RescueFunds_OnlyMaker() public {
        _createEscrow(_defaultProgram());
        dai.mint(address(escrow), 123e18);
        vm.expectRevert(abi.encodeWithSelector(NativeOrderEscrow.NotMaker.selector, address(this), maker));
        escrow.rescueFunds(nativeOrder, IERC20(address(dai)), 123e18);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, IERC20(address(dai)), 123e18);
        assertEq(dai.balanceOf(maker), 123e18);
    }

    function test_NativeOrder_RescueFunds_WethLeavesAllowanceAndSignatureActive() public {
        uint40 expiration = uint40(block.timestamp + 10 days);
        _createOrder(_buildOrder(_program(expiration)), WETH_AMOUNT, expiration);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, IERC20(address(weth)), 0.25 ether);
        assertEq(weth.balanceOf(maker), 0.25 ether);
        assertEq(weth.balanceOf(address(escrow)), 0.75 ether);
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
    }

    function test_NativeOrder_RescueFunds_OtherTokenDoesNotAffectOrder() public {
        uint40 expiration = uint40(block.timestamp + 10 days);
        _createOrder(_buildOrder(_program(expiration)), WETH_AMOUNT, expiration);
        dai.mint(address(escrow), 123e18);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, IERC20(address(dai)), 123e18);
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(dai.balanceOf(maker), 123e18);
    }

    function test_NativeOrder_RescueFunds_ForcedEth() public {
        _createEscrow(_defaultProgram());
        vm.deal(address(escrow), 0.7 ether);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, IERC20(address(0)), 0.3 ether);
        assertEq(maker.balance - makerBefore, 0.3 ether);
        assertEq(address(escrow).balance, 0.4 ether);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    // Failed ETH payouts roll back closure and unwrap; callbacks cannot earn a second reward.

    function test_NativeOrder_Cancel_RejectingMakerRollsBack() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, true, false);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrow.ETHTransferFailed.selector);
        escrow.cancel(nativeOrder);
        _assertCancellationRolledBack();
        receiver.configure(escrow, nativeOrder, false, false);
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(receiver.received(), WETH_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_RejectingMakerRollsBackResolverReward() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, true, false);
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        vm.prank(resolver);
        vm.expectRevert(NativeOrderEscrow.ETHTransferFailed.selector);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, 0);
        _assertCancellationRolledBack();
    }

    function test_NativeOrder_CancelExpiredForReward_RejectingResolverRollsBack() public {
        _createEscrow(_defaultProgram());
        NativeOrderReceiver receiver = new NativeOrderReceiver();
        receiver.configure(escrow, nativeOrder, true, false);
        accessToken.mint(address(receiver), 1);
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        uint256 makerBefore = maker.balance;
        vm.prank(address(receiver));
        vm.expectRevert(NativeOrderEscrow.ETHTransferFailed.selector);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(maker.balance, makerBefore);
        _assertCancellationRolledBack();
    }

    function test_NativeOrder_CancelExpiredForReward_MakerCallbackCannotClaimAnotherReward() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, false, true);
        accessToken.mint(maker, 1);
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        uint256 reward = uint256(MAX_BASE_FEE) * CANCEL_GAS_REFUND;
        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);
        assertEq(resolver.balance, reward);
        assertEq(receiver.received(), WETH_AMOUNT - reward);
        assertEq(receiver.reentrantError(), NativeOrderEscrow.CancelForZeroBalance.selector);
        assertEq(receiver.callbacks(), 1);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_MakerCallbackCannotRescuePayoutAgain() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, false, false);
        receiver.enableRescueDuringCallback();
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        uint256 reward = uint256(MAX_BASE_FEE) * CANCEL_GAS_REFUND;

        vm.prank(resolver);
        escrow.cancelExpiredForReward(nativeOrder);

        assertEq(resolver.balance, reward);
        assertEq(receiver.received(), WETH_AMOUNT - reward);
        assertEq(receiver.rescueAttempts(), 1);
        assertEq(receiver.rescuedDuringCallback(), 0);
        assertEq(receiver.callbacks(), 1);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_NativeOrder_CancelExpiredForReward_ResolverCallbackCannotClaimAnotherReward() public {
        _createEscrow(_defaultProgram());
        NativeOrderReceiver receiver = new NativeOrderReceiver();
        receiver.configure(escrow, nativeOrder, false, true);
        accessToken.mint(address(receiver), 1);
        vm.fee(MAX_BASE_FEE);
        vm.warp(_rewardCancelStart());
        uint256 reward = uint256(MAX_BASE_FEE) * CANCEL_GAS_REFUND;
        uint256 makerBefore = maker.balance;

        vm.prank(address(receiver));
        escrow.cancelExpiredForReward(nativeOrder);

        assertEq(receiver.received(), reward);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT - reward);
        assertEq(receiver.reentrantError(), NativeOrderEscrow.CancelForZeroBalance.selector);
        assertEq(receiver.callbacks(), 1);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    // Helpers.

    function _tokenA() private view returns (address) {
        return isAToB ? address(dai) : address(weth);
    }

    function _tokenB() private view returns (address) {
        return isAToB ? address(weth) : address(dai);
    }

    function _expiration() private view returns (uint40) {
        return uint40(block.timestamp + EXPIRY_OFFSET);
    }

    function _orderExpiration() private view returns (uint256) {
        return uint40(nativeOrder._packed >> 160);
    }

    function _rewardCancelStart() private view returns (uint256) {
        return _orderExpiration() + PUBLIC_CANCEL_DELAY;
    }

    function _defaultProgram() private view returns (bytes memory) {
        return _program(_expiration());
    }

    function _program(uint40 deadline) private view returns (bytes memory) {
        return bytes.concat(
            Deadline.build(deadline),
            StaticBalances.build(isAToB ? DAI_AMOUNT : WETH_AMOUNT, isAToB ? WETH_AMOUNT : DAI_AMOUNT),
            InvalidateTokenOut.build(),
            LimitSwap.build(address(dai), address(weth))
        );
    }

    function _orderArgs(bytes memory program) private view returns (TraitsHelper.MakerTraitsLibArgs memory args) {
        args.maker = maker;
        args.receiver = maker;
        args.tokenA = _tokenA();
        args.tokenB = _tokenB();
        args.program = program;
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(_orderArgs(program));
    }

    function _hookOrderArgs(bytes memory program) private view returns (MakerTraitsLib.Args memory args) {
        args.maker = maker;
        args.receiver = maker;
        args.tokenA = _tokenA();
        args.tokenB = _tokenB();
        args.program = program;
    }

    function _createEscrow(bytes memory program) private {
        _createOrder(_buildOrder(program), WETH_AMOUNT, _expiration());
    }

    function _createOrder(ISwapVM.Order memory order, uint256 amount, uint40 expiration) private {
        _createOrder(order, amount, expiration, MAX_BASE_FEE);
    }

    function _createOrder(ISwapVM.Order memory order, uint256 amount, uint40 expiration, uint56 maxBaseFee) private {
        makerOrder = order;
        bytes32 dataHash = keccak256(order.data);
        nativeOrder = NativeOrderLib.encode(order.maker, order.traits, dataHash, expiration, maxBaseFee);
        vm.prank(order.maker);
        address escrowAddress = factory.create{ value: amount }(order.traits, dataHash, expiration, maxBaseFee);
        escrow = NativeOrderEscrow(payable(escrowAddress));
        filledOrder = order;
        filledOrder.maker = escrowAddress;
        filledOrderHash = router.hash(filledOrder);
    }

    function _contractMaker() private returns (NativeOrderReceiver receiver) {
        receiver = new NativeOrderReceiver();
        maker = address(receiver);
        vm.deal(maker, 100 ether);
        _createEscrow(_defaultProgram());
    }

    function _quoteSucceeds() private view returns (bool) {
        try router.asView().quote(filledOrder, 0.1 ether, _takerData(false)) returns (uint256, uint256, bytes32) {
            return true;
        } catch {
            return false;
        }
    }

    function _donateWeth(uint256 amount) private {
        weth.deposit{ value: amount }();
        weth.transfer(address(escrow), amount);
    }

    function _signature() private view returns (bytes memory) {
        return abi.encode(nativeOrder);
    }

    function _takerData(bool isExactIn) private view returns (bytes memory) {
        return _takerData(isExactIn, _signature());
    }

    function _takerData(bool isExactIn, bytes memory signature) private view returns (bytes memory) {
        TraitsHelper.TakerTraitsLibArgs memory args;
        args.isExactIn = isExactIn;
        args.isAToB = isAToB;
        args.allowPartialFill = true;
        args.to = address(this);
        args.signature = signature;
        return orders.TakerTraitsLibBuild(args);
    }

    function _expectBadSignature(bytes memory signature) private {
        vm.expectRevert(abi.encodeWithSelector(
            OrderRegistrator.BadSignature.selector, address(escrow), router.hash(filledOrder), signature
        ));
    }

    function _assertCancellationRolledBack() private view {
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(address(escrow).balance, 0);
        assertEq(router.tokenOutInvalidators(address(escrow), filledOrderHash, address(weth)), 0);
    }

    function _tamper(uint8 field, uint256 bit) private view returns (NativeOrder memory tampered) {
        tampered = nativeOrder;
        if (field == 0) {
            tampered._traits = MakerTraits.wrap(MakerTraits.unwrap(tampered._traits) ^ (uint256(1) << (bit % 256)));
        } else if (field == 1) {
            tampered._dataHash ^= bytes32(uint256(1) << (bit % 256));
        } else if (field == 2) {
            tampered._packed ^= uint256(1) << (bit % 160);
        } else if (field == 3) {
            tampered._packed ^= uint256(1) << (160 + bit % 40);
        } else {
            tampered._packed ^= uint256(1) << (200 + bit % 56);
        }
    }

    function _assertInvalidOrder(NativeOrder memory tampered) private {
        address tamperedEscrow = factory.addressOfEscrow(tampered);
        assertTrue(tamperedEscrow != address(escrow));
        assertEq(escrow.isValidSignature(filledOrderHash, abi.encode(tampered)), bytes4(0));
        vm.prank(address(uint160(tampered._packed)));
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.BadOrder.selector, tamperedEscrow, address(escrow))
        );
        escrow.cancel(tampered);
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.BadOrder.selector, tamperedEscrow, address(escrow))
        );
        escrow.cancelExpired(tampered);
        vm.prank(address(uint160(tampered._packed)));
        vm.expectRevert(
            abi.encodeWithSelector(NativeOrderEscrow.BadOrder.selector, tamperedEscrow, address(escrow))
        );
        escrow.rescueFunds(tampered, IERC20(address(weth)), 1);
    }

    function assertNativeOrderGetters(
        NativeOrder calldata order,
        address maker_,
        uint256 traits_,
        bytes32 dataHash_,
        uint40 expiration_,
        uint56 maxBaseFee_
    ) external pure {
        _assertNativeOrderGetters(order, maker_, traits_, dataHash_, expiration_, maxBaseFee_);
    }

    function assertWrappedNativeOrderGetters(
        bytes calldata signature,
        address maker_,
        uint256 traits_,
        bytes32 dataHash_,
        uint40 expiration_,
        uint56 maxBaseFee_
    ) external pure {
        NativeOrder calldata order = NativeOrderLib.wrap(signature);
        assertEq(order.salt(), keccak256(signature));
        _assertNativeOrderGetters(order, maker_, traits_, dataHash_, expiration_, maxBaseFee_);
    }

    function _assertNativeOrderGetters(
        NativeOrder calldata order,
        address maker_,
        uint256 traits_,
        bytes32 dataHash_,
        uint40 expiration_,
        uint56 maxBaseFee_
    ) private pure {
        assertEq(order.maker(), maker_);
        assertEq(MakerTraits.unwrap(order.traits()), traits_);
        assertEq(order.dataHash(), dataHash_);
        assertEq(order.expiration(), expiration_);
        assertEq(order.maxBaseFee(), maxBaseFee_);
    }

    receive() external payable {}
}
