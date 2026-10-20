// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { EthReceiver } from "@1inch/solidity-utils/contracts/mixins/EthReceiver.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { OrderRegistrator } from "../../contracts/extensions/OrderRegistrator.sol";
import { MakerTraits, MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { Deadline, Salt } from "../../contracts/instructions/Controls.sol";
import { InvalidateTokenOut } from "../../contracts/instructions/Invalidators.sol";
import { NativeOrder, NativeOrderEscrow } from "../../contracts/extensions/nativeorder/NativeOrderEscrow.sol";
import { NativeOrderEscrowFactory } from "../../contracts/extensions/nativeorder/NativeOrderEscrowFactory.sol";
import { WETHMock } from "./mocks/WETHMock.sol";
import { MockMakerHooks } from "./mocks/MockMakerHooks.sol";

contract NativeOrderEscrowTest is Test {
    uint256 private constant WETH_AMOUNT = 1 ether;
    uint256 private constant DAI_AMOUNT = 3000e18;
    uint40 private constant EXPIRY_OFFSET = 1 days;
    uint40 private constant PUBLIC_CANCEL_OFFSET = 1 days + 1 hours;
    uint32 private constant RESCUE_DELAY = 7 days;
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

    SwapVMRouter public router;
    WETHMock public weth;
    TokenMock public dai;
    TokenMock public accessToken;
    NativeOrderEscrowFactory public factory;
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
        router = new SwapVMRouter(address(0), address(weth), address(this), "SwapVM", "1.0.0");
        factory = new NativeOrderEscrowFactory(
            ISwapVM(address(router)), IWETH(address(weth)), IERC20(address(accessToken)), RESCUE_DELAY
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

    function test_FullFill_ExactOut() public {
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
        _assertSignatureInvalid();
    }

    function test_FullFill_ExactIn() public {
        _createEscrow(_defaultProgram());
        (uint256 amountIn, uint256 amountOut,) = router.swap(filledOrder, DAI_AMOUNT, _takerData(true));
        assertEq(amountIn, DAI_AMOUNT);
        assertEq(amountOut, WETH_AMOUNT);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
        assertEq(weth.balanceOf(address(this)), WETH_AMOUNT);
    }

    function test_FullFill_TakerReceivesNativeEth() public {
        _createEscrow(_defaultProgram());
        TakerTraitsLib.Args memory args;
        args.isAToB = isAToB;
        args.shouldUnwrapWeth = true;
        args.signature = _signature();
        uint256 ethBefore = address(this).balance;
        router.swap(filledOrder, WETH_AMOUNT, TakerTraitsLib.build(args));
        assertEq(address(this).balance - ethBefore, WETH_AMOUNT);
        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
    }

    function test_PartialFills_ThenCancelRemainder() public {
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
        _assertClosed();
    }

    function test_ExplicitReceiverReceivesProceedsButMakerOwnsRefund() public {
        address recipient = makeAddr("recipient");
        MakerTraitsLib.Args memory args = _orderArgs(_defaultProgram());
        args.receiver = recipient;
        _createOrder(MakerTraitsLib.build(args), WETH_AMOUNT, _expiration(), _publicCancellation());
        router.swap(filledOrder, 0.4 ether, _takerData(false));

        assertEq(dai.balanceOf(recipient), 1200e18);
        assertEq(dai.balanceOf(maker), 0);
        vm.prank(recipient);
        vm.expectRevert(NativeOrderEscrow.InvalidCaller.selector);
        escrow.cancel(nativeOrder);

        uint256 makerBefore = maker.balance;
        uint256 recipientBefore = recipient.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.6 ether);
        assertEq(recipient.balance, recipientBefore);
        assertEq(dai.balanceOf(recipient), 1200e18);
        _assertClosed();
    }

    function test_Quote_BeforeAndAfterPartialFill() public {
        _createEscrow(_defaultProgram());
        (uint256 amountIn, uint256 amountOut,) = router.asView().quote(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(amountIn, DAI_AMOUNT);
        assertEq(amountOut, WETH_AMOUNT);
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        (amountIn, amountOut,) = router.asView().quote(filledOrder, 0.6 ether, _takerData(false));
        assertEq(amountIn, 1800e18);
        assertEq(amountOut, 0.6 ether);
    }

    function test_Fill_AfterProgramDeadline() public {
        uint40 deadline = uint40(block.timestamp + EXPIRY_OFFSET / 2);
        _createEscrow(_program(deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Deadline.DeadlineReached.selector, deadline));
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
    }

    function test_Fill_ExpirationBoundary() public {
        _createEscrow(_program(uint40(block.timestamp + 2 * EXPIRY_OFFSET)));
        vm.warp(nativeOrder.expiration - 1);
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
        router.swap(filledOrder, 0.5 ether, _takerData(false));
        vm.warp(nativeOrder.expiration);
        _assertSignatureInvalid();
        _expectBadSignature(_signature());
        router.swap(filledOrder, 0.5 ether, _takerData(false));
    }

    function test_DepositAndApprove_OnlyFactory() public {
        _createEscrow(_defaultProgram());
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrow.InvalidCaller.selector);
        escrow.depositAndApprove{ value: 1 ether }();
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    // Maker cancellation permanently closes allowance and router invalidation.

    function test_Cancel_RefundsAndBlocksFillsAndQuotes() public {
        _createEscrow(_defaultProgram());
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
        _assertClosed();
        assertFalse(_quoteSucceeds());
        _expectBadSignature(_signature());
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
    }

    function test_Cancel_OnlyMaker() public {
        _createEscrow(_defaultProgram());
        vm.expectRevert(NativeOrderEscrow.InvalidCaller.selector);
        escrow.cancel(nativeOrder);
    }

    function test_Cancel_IsIdempotentAndSweepsLaterDonations() public {
        _createEscrow(_defaultProgram());
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        _donateWeth(0.3 ether);
        vm.deal(address(escrow), 0.2 ether); // Forced ETH bypasses the receive function.
        _assertSignatureInvalid();
        _expectBadSignature(_signature());
        router.swap(filledOrder, 0.1 ether, _takerData(false));
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.5 ether);
        _assertClosed();
    }

    function test_FullFill_DonationCannotReviveAndMakerCanSweep() public {
        _createEscrow(_defaultProgram());
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        _donateWeth(0.3 ether);
        _assertSignatureInvalid();
        _expectBadSignature(_signature());
        router.swap(filledOrder, 0.1 ether, _takerData(false));
        vm.warp(nativeOrder.publicCancellation);
        vm.prank(resolver);
        vm.expectRevert(NativeOrderEscrow.OrderClosed.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.3 ether);
        _assertClosed();
    }

    function test_Cancel_RefundsForcedEthOnlyToMaker() public {
        _createEscrow(_defaultProgram());
        vm.deal(address(escrow), 0.7 ether);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 1.7 ether);
        _assertClosed();
    }

    function test_DirectEthTransferIsRejected() public {
        _createEscrow(_defaultProgram());
        (bool success, bytes memory reason) = address(escrow).call{ value: 1 }("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(EthReceiver.EthDepositRejected.selector));
        assertEq(address(escrow).balance, 0);
    }

    // Resolver access, timing, reward accounting and repeat cleanup.

    function test_PublicCancel_TimeAndAccessGates() public {
        _createEscrow(_defaultProgram());
        vm.warp(nativeOrder.publicCancellation - 1);
        vm.prank(resolver);
        vm.expectRevert(NativeOrderEscrow.InvalidTime.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        vm.warp(nativeOrder.publicCancellation);
        vm.expectRevert(NativeOrderEscrow.InvalidCaller.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        // Eligibility is checked at cancellation, rather than snapshotted at creation.
        vm.prank(resolver);
        accessToken.transfer(address(this), 1);
        vm.prank(resolver);
        vm.expectRevert(NativeOrderEscrow.InvalidCaller.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        accessToken.transfer(resolver, 1);
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, 0);
        _assertClosed();
    }

    function test_PublicCancel_BaseFeeRewardAndForcedEthRefund() public {
        _createEscrow(_defaultProgram());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        vm.deal(address(escrow), 2 ether);
        uint256 reward = 10 gwei * 120_000 * 110 / 100;
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, reward);
        assertEq(maker.balance - makerBefore, 3 ether - reward);
        _assertClosed();
    }

    function test_PublicCancel_RewardLimit() public {
        _createEscrow(_defaultProgram());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, 100);
        assertEq(resolver.balance, 100);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT - 100);
    }

    function test_PublicCancel_ZeroRewardLimit() public {
        _createEscrow(_defaultProgram());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, 0);
        assertEq(resolver.balance, 0);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
    }

    function test_PublicCancel_ZeroBaseFee() public {
        _createEscrow(_defaultProgram());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(0);
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, 0);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
    }

    function test_PublicCancel_RewardCappedByRemainingAllowanceNotDonations() public {
        _createEscrow(_defaultProgram());
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        _donateWeth(2 ether);
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(1 ether);
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, 0.6 ether);
        assertEq(maker.balance - makerBefore, 2 ether);
        _assertClosed();
    }

    function test_PublicCancel_RewardCappedByLiveWethBalance() public {
        _createEscrow(_defaultProgram());
        // Model a token balance deficit without changing the escrow's allowance.
        vm.prank(address(escrow));
        weth.transfer(address(this), WETH_AMOUNT - 123);
        vm.deal(address(escrow), 1 ether);
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(1 ether);
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, 123);
        assertEq(maker.balance - makerBefore, 1 ether);
        _assertClosed();
    }

    function test_PublicCancel_DustRemainder() public {
        _createOrder(_buildOrder(_defaultProgram()), 1, _expiration(), _publicCancellation());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, 1);
        _assertClosed();
    }

    function test_PublicCancel_CannotRewardTwiceEvenAfterDonation() public {
        _createEscrow(_defaultProgram());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        uint256 resolverBefore = resolver.balance;
        _donateWeth(WETH_AMOUNT);
        vm.prank(resolver);
        vm.expectRevert(NativeOrderEscrow.OrderClosed.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, resolverBefore);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT);
    }

    function testFuzz_PublicCancel_ConservesFunds(uint96 deposit, uint96 rewardLimit, uint64 baseFee) public {
        deposit = uint96(bound(deposit, 1, 10 ether));
        baseFee = uint64(bound(baseFee, 0, 100 gwei));
        _createOrder(_buildOrder(_defaultProgram()), deposit, _expiration(), _publicCancellation());
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(baseFee);
        uint256 reward = uint256(baseFee) * 120_000 * 110 / 100;
        if (reward > rewardLimit) reward = rewardLimit;
        if (reward > deposit) reward = deposit;
        uint256 makerBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, rewardLimit);
        assertEq(resolver.balance, reward);
        assertEq(maker.balance - makerBefore, deposit - reward);
        _assertClosed();
    }

    // ERC-1271 commits to every term through the escrow's CREATE2 address.

    function test_IsValidSignature_AcceptsCommittedOrder() public {
        _createEscrow(_defaultProgram());
        assertEq(_signature().length, 224);
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
    }

    function test_IsValidSignature_WrongHash() public {
        _createEscrow(_defaultProgram());
        assertEq(escrow.isValidSignature(bytes32(uint256(1)), _signature()), bytes4(0));
    }

    function test_IsValidSignature_AllCommittedFieldsAreAuthenticated() public {
        _createEscrow(_defaultProgram());
        for (uint8 field = 0; field < 7; ++field) _assertInvalidOrder(_tamper(field, 0));
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
    }

    function testFuzz_IsValidSignature_TamperedCommitment(uint8 field, uint256 bit) public {
        _createEscrow(_defaultProgram());
        _assertInvalidOrder(_tamper(uint8(bound(field, 0, 6)), bit));
    }

    function testFuzz_IsValidSignature_MalformedLength(uint16 length) public {
        _createEscrow(_defaultProgram());
        length = uint16(bound(length, 0, 512));
        if (length == 224) ++length;
        assertEq(escrow.isValidSignature(filledOrderHash, new bytes(length)), bytes4(0));
    }

    function test_IsValidSignature_TrailingDataRejected() public {
        _createEscrow(_defaultProgram());
        assertEq(escrow.isValidSignature(filledOrderHash, bytes.concat(_signature(), hex"00")), bytes4(0));
    }

    function test_IsValidSignature_NoncanonicalAddressCannotAuthenticate() public {
        _createEscrow(_defaultProgram());
        bytes memory signature = _signature();
        assembly ("memory-safe") {
            mstore(add(signature, 32), or(mload(add(signature, 32)), shl(160, 1)))
        }
        (bool success, bytes memory result) = address(escrow).staticcall(
            abi.encodeCall(NativeOrderEscrow.isValidSignature, (filledOrderHash, signature))
        );
        // Solidity's ABI decoder may reject noncanonical values before the function can return zero.
        if (success) assertEq(abi.decode(result, (bytes4)), bytes4(0));
    }

    function test_Swap_TamperedSignatureRevertsBadSignature() public {
        _createEscrow(_defaultProgram());
        bytes memory signature = abi.encode(_tamper(3, 0));
        _expectBadSignature(signature);
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false, signature));
    }

    function test_IsValidSignature_ProgramAndTraitsCannotBeReplaced() public {
        _createEscrow(_defaultProgram());
        ISwapVM.Order memory attackerOrder = filledOrder;
        attackerOrder.data = bytes.concat(attackerOrder.data, Salt.build(uint64(1)));
        assertEq(escrow.isValidSignature(router.hash(attackerOrder), _signature()), bytes4(0));
        attackerOrder = filledOrder;
        attackerOrder.traits = MakerTraits.wrap(MakerTraits.unwrap(attackerOrder.traits) ^ 1);
        assertEq(escrow.isValidSignature(router.hash(attackerOrder), _signature()), bytes4(0));
    }

    // Factory guards against configurations changed by replacing maker with the escrow.

    function test_Create_ZeroDepositAndOnlyMaker() public {
        ISwapVM.Order memory order = _buildOrder(_defaultProgram());
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderZeroDeposit.selector);
        factory.create(order, _expiration(), _publicCancellation());
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderOnlyMakerCanCreate.selector);
        factory.create{ value: WETH_AMOUNT }(order, _expiration(), _publicCancellation());
    }

    function test_Create_AquaRejected() public {
        MakerTraitsLib.Args memory args = _orderArgs(_defaultProgram());
        args.useAquaInsteadOfSignature = true;
        ISwapVM.Order memory order = MakerTraitsLib.build(args);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderAquaNotSupported.selector);
        factory.create{ value: WETH_AMOUNT }(order, _expiration(), _publicCancellation());
    }

    function test_Create_ExplicitReceiverRequired() public {
        MakerTraitsLib.Args memory args = _orderArgs(_defaultProgram());
        args.receiver = address(0);
        ISwapVM.Order memory order = MakerTraitsLib.build(args);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderExplicitReceiverRequired.selector);
        factory.create{ value: WETH_AMOUNT }(order, _expiration(), _publicCancellation());
        args.receiver = address(factory);
        order = MakerTraitsLib.build(args);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderExplicitReceiverRequired.selector);
        factory.create{ value: WETH_AMOUNT }(order, _expiration(), _publicCancellation());
    }

    function test_Create_TokensMustContainWethAndBeSorted() public {
        ISwapVM.Order memory order = _buildOrder(_defaultProgram());
        order.data = abi.encodePacked(address(1), address(2));
        _expectInvalidTokens(order);
        order.data = abi.encodePacked(_tokenB(), _tokenA());
        _expectInvalidTokens(order);
        order.data = abi.encodePacked(address(weth), address(weth));
        _expectInvalidTokens(order);
        order.data = new bytes(39);
        _expectInvalidTokens(order);
    }

    function test_Create_AbsoluteTimeBounds() public {
        ISwapVM.Order memory order = _buildOrder(_defaultProgram());
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderInvalidTime.selector);
        factory.create{ value: WETH_AMOUNT }(order, uint40(block.timestamp), _publicCancellation());
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderInvalidTime.selector);
        factory.create{ value: WETH_AMOUNT }(order, _expiration(), _expiration() - 1);
        // Cancellation may open at the precise instant signatures expire.
        _createOrder(order, WETH_AMOUNT, _expiration(), _expiration());
        vm.warp(nativeOrder.expiration);
        _assertSignatureInvalid();
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, 0);
        _assertClosed();
    }

    function test_Create_ImplicitHooksRejectedForEveryStage() public {
        for (uint8 stage = 0; stage < 4; ++stage) {
            MakerTraitsLib.Args memory args = _orderArgs(_defaultProgram());
            if (stage == 0) args.hasPreTransferInHook = true;
            else if (stage == 1) args.hasPostTransferInHook = true;
            else if (stage == 2) args.hasPreTransferOutHook = true;
            else args.hasPostTransferOutHook = true;
            ISwapVM.Order memory order = MakerTraitsLib.build(args);
            vm.prank(maker);
            vm.expectRevert(NativeOrderEscrowFactory.NativeOrderExplicitHookTargetRequired.selector);
            factory.create{ value: WETH_AMOUNT }(order, _expiration(), _publicCancellation());
        }
        assertEq(address(factory).balance, 0);
    }

    function test_Create_ExplicitHooksExecuteForEveryStage() public {
        MockMakerHooks hooks = new MockMakerHooks();
        MakerTraitsLib.Args memory args = _orderArgs(_defaultProgram());
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
        _createOrder(MakerTraitsLib.build(args), WETH_AMOUNT, _expiration(), _publicCancellation());
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(hooks.preTransferInCallCount(), 1);
        assertEq(hooks.postTransferInCallCount(), 1);
        assertEq(hooks.preTransferOutCallCount(), 1);
        assertEq(hooks.postTransferOutCallCount(), 1);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
    }

    function test_Create_DuplicateRejectedSaltDifferentiates() public {
        _createEscrow(_defaultProgram());
        address first = address(escrow);
        vm.prank(maker);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.create{ value: WETH_AMOUNT }(makerOrder, _expiration(), _publicCancellation());
        _createEscrow(bytes.concat(Salt.build(uint64(1)), _defaultProgram()));
        assertTrue(address(escrow) != first);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    function test_Create_AddressHashAndTermsConsistency() public {
        uint256 createdAt = block.timestamp;
        _createEscrow(_defaultProgram());
        assertEq(factory.addressOfEscrow(nativeOrder), address(escrow));
        assertEq(router.hash(filledOrder), filledOrderHash);
        assertEq(nativeOrder.maker, maker);
        assertEq(MakerTraits.unwrap(nativeOrder.traits), MakerTraits.unwrap(makerOrder.traits));
        assertEq(nativeOrder.dataHash, keccak256(makerOrder.data));
        assertEq(nativeOrder.amount, WETH_AMOUNT);
        assertEq(nativeOrder.expiration, createdAt + EXPIRY_OFFSET);
        assertEq(nativeOrder.publicCancellation, createdAt + PUBLIC_CANCEL_OFFSET);
        assertEq(nativeOrder.rescueAfter, createdAt + RESCUE_DELAY);
        assertEq(address(escrow.ROUTER()), address(router));
        assertEq(address(escrow.WETH()), address(weth));
        assertEq(escrow.FACTORY(), address(factory));
    }

    // Chain changes affect the typed order hash, without locking away refunds.

    function test_ChainIdChange_AfterCreationStillFillsAndCancels() public {
        _createEscrow(_defaultProgram());
        bytes32 oldHash = filledOrderHash;
        vm.chainId(block.chainid + 1);
        filledOrderHash = router.hash(filledOrder);
        assertTrue(filledOrderHash != oldHash);
        assertEq(factory.addressOfEscrow(nativeOrder), address(escrow));
        assertEq(escrow.isValidSignature(oldHash, _signature()), bytes4(0));
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), ERC1271_MAGIC);
        router.swap(filledOrder, 0.4 ether, _takerData(false));
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 0.6 ether);
        _assertClosed();
    }

    function test_ChainIdChange_BeforeCreationMatchesRouter() public {
        vm.chainId(block.chainid + 1);
        _createEscrow(_defaultProgram());
        assertEq(router.hash(filledOrder), filledOrderHash);
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function test_ChainIdChange_AfterCreationRescueStillWorks() public {
        _createEscrow(_defaultProgram());
        dai.mint(address(escrow), 123e18);
        vm.chainId(block.chainid + 1);
        vm.warp(nativeOrder.rescueAfter);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, address(dai), 123e18);
        assertEq(dai.balanceOf(maker), 123e18);
    }

    // Delayed recovery, including closure when the sell token is rescued.

    function test_RescueFunds_TimeBoundaryAndOnlyMaker() public {
        _createEscrow(_defaultProgram());
        dai.mint(address(escrow), 123e18);
        vm.warp(nativeOrder.rescueAfter - 1);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrow.InvalidTime.selector);
        escrow.rescueFunds(nativeOrder, address(dai), 123e18);
        vm.warp(nativeOrder.rescueAfter);
        vm.expectRevert(NativeOrderEscrow.InvalidCaller.selector);
        escrow.rescueFunds(nativeOrder, address(dai), 123e18);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, address(dai), 123e18);
        assertEq(dai.balanceOf(maker), 123e18);
    }

    function test_RescueFunds_WethClosesLiveOrderBeforeExpiry() public {
        uint40 expiration = uint40(block.timestamp + 10 days);
        _createOrder(_buildOrder(_program(expiration)), WETH_AMOUNT, expiration, expiration);
        vm.warp(nativeOrder.rescueAfter);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, address(weth), 0.25 ether);
        assertEq(weth.balanceOf(maker), 0.25 ether);
        assertEq(weth.allowance(address(escrow), address(router)), 0);
        _donateWeth(WETH_AMOUNT);
        _assertSignatureInvalid();
        assertFalse(_quoteSucceeds());
        _expectBadSignature(_signature());
        router.swap(filledOrder, 0.1 ether, _takerData(false));
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(maker.balance - makerBefore, 1.75 ether);
        _assertClosed();
    }

    function test_RescueFunds_OtherTokenDoesNotCloseLiveOrder() public {
        uint40 expiration = uint40(block.timestamp + 10 days);
        _createOrder(_buildOrder(_program(expiration)), WETH_AMOUNT, expiration, expiration);
        dai.mint(address(escrow), 123e18);
        vm.warp(nativeOrder.rescueAfter);
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, address(dai), 123e18);
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false));
        assertEq(dai.balanceOf(maker), DAI_AMOUNT + 123e18);
    }

    function test_RescueFunds_ForcedEth() public {
        _createEscrow(_defaultProgram());
        vm.deal(address(escrow), 0.7 ether);
        vm.warp(nativeOrder.rescueAfter);
        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        escrow.rescueFunds(nativeOrder, address(0), 0.3 ether);
        assertEq(maker.balance - makerBefore, 0.3 ether);
        assertEq(address(escrow).balance, 0.4 ether);
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    // Failed ETH payouts roll back closure and unwrap; callbacks cannot earn a second reward.

    function test_Cancel_RejectingMakerRollsBack() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, true, false);
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrow.NativeTokenSendingFailure.selector);
        escrow.cancel(nativeOrder);
        _assertCancellationRolledBack();
        receiver.configure(escrow, nativeOrder, false, false);
        vm.prank(maker);
        escrow.cancel(nativeOrder);
        assertEq(receiver.received(), WETH_AMOUNT);
        _assertClosed();
    }

    function test_PublicCancel_RejectingMakerRollsBackResolverReward() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, true, false);
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        vm.prank(resolver);
        vm.expectRevert(NativeOrderEscrow.NativeTokenSendingFailure.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, 0);
        _assertCancellationRolledBack();
    }

    function test_PublicCancel_RejectingResolverRollsBack() public {
        _createEscrow(_defaultProgram());
        NativeOrderReceiver receiver = new NativeOrderReceiver();
        receiver.configure(escrow, nativeOrder, true, false);
        accessToken.mint(address(receiver), 1);
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        uint256 makerBefore = maker.balance;
        vm.prank(address(receiver));
        vm.expectRevert(NativeOrderEscrow.NativeTokenSendingFailure.selector);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(maker.balance, makerBefore);
        _assertCancellationRolledBack();
    }

    function test_PublicCancel_MakerCallbackCannotClaimAnotherReward() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, false, true);
        accessToken.mint(maker, 1);
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        uint256 reward = 10 gwei * 120_000 * 110 / 100;
        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);
        assertEq(resolver.balance, reward);
        assertEq(receiver.received(), WETH_AMOUNT - reward);
        assertEq(receiver.reentrantError(), NativeOrderEscrow.OrderClosed.selector);
        assertEq(receiver.callbacks(), 1);
        _assertClosed();
    }

    function test_PublicCancel_MakerCallbackCannotRescueReservedReward() public {
        NativeOrderReceiver receiver = _contractMaker();
        receiver.configure(escrow, nativeOrder, false, false);
        receiver.enableRescueDuringCallback();
        vm.warp(nativeOrder.rescueAfter);
        vm.fee(10 gwei);
        uint256 reward = 10 gwei * 120_000 * 110 / 100;

        vm.prank(resolver);
        escrow.publicCancel(nativeOrder, type(uint256).max);

        assertEq(resolver.balance, reward);
        assertEq(receiver.received(), WETH_AMOUNT - reward);
        assertEq(receiver.rescueAttempts(), 1);
        assertEq(receiver.rescuedDuringCallback(), 0);
        assertEq(receiver.callbacks(), 1);
        _assertClosed();
    }

    function test_PublicCancel_ResolverCallbackCannotClaimAnotherReward() public {
        _createEscrow(_defaultProgram());
        NativeOrderReceiver receiver = new NativeOrderReceiver();
        receiver.configure(escrow, nativeOrder, false, true);
        accessToken.mint(address(receiver), 1);
        vm.warp(nativeOrder.publicCancellation);
        vm.fee(10 gwei);
        uint256 reward = 10 gwei * 120_000 * 110 / 100;
        uint256 makerBefore = maker.balance;

        vm.prank(address(receiver));
        escrow.publicCancel(nativeOrder, type(uint256).max);

        assertEq(receiver.received(), reward);
        assertEq(maker.balance - makerBefore, WETH_AMOUNT - reward);
        assertEq(receiver.reentrantError(), NativeOrderEscrow.OrderClosed.selector);
        assertEq(receiver.callbacks(), 1);
        _assertClosed();
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

    function _publicCancellation() private view returns (uint40) {
        return uint40(block.timestamp + PUBLIC_CANCEL_OFFSET);
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

    function _orderArgs(bytes memory program) private view returns (MakerTraitsLib.Args memory args) {
        args.maker = maker;
        args.receiver = maker;
        args.tokenA = _tokenA();
        args.tokenB = _tokenB();
        args.program = program;
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(_orderArgs(program));
    }

    function _createEscrow(bytes memory program) private {
        _createOrder(_buildOrder(program), WETH_AMOUNT, _expiration(), _publicCancellation());
    }

    function _createOrder(ISwapVM.Order memory order, uint256 amount, uint40 expiration, uint40 publicCancellation) private {
        makerOrder = order;
        vm.prank(order.maker);
        (address escrowAddress, bytes32 orderHash, NativeOrder memory terms) =
            factory.create{ value: amount }(order, expiration, publicCancellation);
        escrow = NativeOrderEscrow(payable(escrowAddress));
        filledOrderHash = orderHash;
        nativeOrder = terms;
        filledOrder = order;
        filledOrder.maker = escrowAddress;
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
        TakerTraitsLib.Args memory args;
        args.isExactIn = isExactIn;
        args.isAToB = isAToB;
        args.allowPartialFill = true;
        args.to = address(this);
        args.signature = signature;
        return TakerTraitsLib.build(args);
    }

    function _expectBadSignature(bytes memory signature) private {
        vm.expectRevert(abi.encodeWithSelector(
            OrderRegistrator.BadSignature.selector, address(escrow), router.hash(filledOrder), signature
        ));
    }

    function _expectInvalidTokens(ISwapVM.Order memory order) private {
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderInvalidTokens.selector);
        factory.create{ value: WETH_AMOUNT }(order, _expiration(), _publicCancellation());
    }

    function _assertSignatureInvalid() private view {
        assertEq(escrow.isValidSignature(filledOrderHash, _signature()), bytes4(0));
    }

    function _assertClosed() private view {
        assertEq(weth.allowance(address(escrow), address(router)), 0);
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(address(escrow).balance, 0);
        assertEq(router.tokenOutInvalidators(address(escrow), filledOrderHash, address(weth)), type(uint256).max);
        _assertSignatureInvalid();
    }

    function _assertCancellationRolledBack() private view {
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
        assertEq(weth.allowance(address(escrow), address(router)), WETH_AMOUNT);
        assertEq(address(escrow).balance, 0);
        assertEq(router.tokenOutInvalidators(address(escrow), filledOrderHash, address(weth)), 0);
    }

    function _tamper(uint8 field, uint256 bit) private view returns (NativeOrder memory tampered) {
        tampered = nativeOrder;
        if (field == 0) tampered.maker = address(uint160(tampered.maker) ^ uint160(uint256(1) << (bit % 160)));
        else if (field == 1) tampered.traits = MakerTraits.wrap(MakerTraits.unwrap(tampered.traits) ^ (uint256(1) << (bit % 256)));
        else if (field == 2) tampered.dataHash ^= bytes32(uint256(1) << (bit % 256));
        else if (field == 3) tampered.amount ^= uint256(1) << (bit % 256);
        else if (field == 4) tampered.expiration ^= uint40(uint256(1) << (bit % 40));
        else if (field == 5) tampered.publicCancellation ^= uint40(uint256(1) << (bit % 40));
        else tampered.rescueAfter ^= uint40(uint256(1) << (bit % 40));
    }

    function _assertInvalidOrder(NativeOrder memory tampered) private {
        assertTrue(factory.addressOfEscrow(tampered) != address(escrow));
        assertEq(escrow.isValidSignature(filledOrderHash, abi.encode(tampered)), bytes4(0));
        vm.prank(tampered.maker);
        vm.expectRevert(NativeOrderEscrow.InvalidOrder.selector);
        escrow.cancel(tampered);
        vm.expectRevert(NativeOrderEscrow.InvalidOrder.selector);
        escrow.publicCancel(tampered, type(uint256).max);
        vm.prank(tampered.maker);
        vm.expectRevert(NativeOrderEscrow.InvalidOrder.selector);
        escrow.rescueFunds(tampered, address(weth), 1);
    }

    receive() external payable {}
}

/// @dev Maker/resolver fixture exercising ETH failure and callback paths.
contract NativeOrderReceiver {
    error RejectEther();

    NativeOrderEscrow private _escrow;
    NativeOrder private _order;
    bool private _rejectsEther;
    bool private _reenters;
    bool private _rescuesEther;
    uint256 public received;
    uint256 public callbacks;
    uint256 public rescueAttempts;
    uint256 public rescuedDuringCallback;
    bytes4 public reentrantError;

    function configure(NativeOrderEscrow escrow, NativeOrder calldata order, bool rejectsEther, bool reenters) external {
        _escrow = escrow;
        _order = order;
        _rejectsEther = rejectsEther;
        _reenters = reenters;
    }

    function enableRescueDuringCallback() external {
        _rescuesEther = true;
    }

    receive() external payable {
        require(!_rejectsEther, RejectEther());
        received += msg.value;
        ++callbacks;
        if (_rescuesEther) {
            _rescuesEther = false;
            ++rescueAttempts;
            rescuedDuringCallback = address(_escrow).balance;
            _escrow.rescueFunds(_order, address(0), rescuedDuringCallback);
        }
        if (_reenters) {
            _reenters = false;
            try _escrow.publicCancel(_order, type(uint256).max) {} catch (bytes memory reason) {
                if (reason.length >= 4) reentrantError = bytes4(reason);
            }
        }
    }
}
