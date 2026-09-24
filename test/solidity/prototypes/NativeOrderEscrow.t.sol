// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../../contracts/routers/SwapVMRouter.sol";
import { OrderRegistrator } from "../../../contracts/extensions/OrderRegistrator.sol";
import { MakerTraitsLib } from "../../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../contracts/libs/TakerTraits.sol";
import { StaticBalances } from "../../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../../contracts/instructions/LimitSwap.sol";
import { Deadline, Salt } from "../../../contracts/instructions/Controls.sol";
import { InvalidateTokenOut } from "../../../contracts/instructions/Invalidators.sol";
import { WETHMock } from "../mocks/WETHMock.sol";

import { NativeOrderEscrow } from "../../../contracts/prototypes/nativeorder/NativeOrderEscrow.sol";
import { NativeOrderEscrowFactory } from "../../../contracts/prototypes/nativeorder/NativeOrderEscrowFactory.sol";
import { IBaseEscrow } from "../../../contracts/prototypes/nativeorder/vendor/interfaces/IBaseEscrow.sol";
import { Timelocks, TimelocksLib } from "../../../contracts/prototypes/nativeorder/vendor/libraries/TimelocksLib.sol";

contract NativeOrderEscrowTest is Test {
    uint256 private constant WETH_AMOUNT = 1 ether;
    uint256 private constant DAI_AMOUNT = 3000e18;
    uint32 private constant EXPIRY_OFFSET = 1 days;
    uint32 private constant PUBLIC_CANCEL_OFFSET = 1 days + 1 hours;
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

    // Current order context, stored to keep helper stack pressure low
    ISwapVM.Order internal makerOrder;
    ISwapVM.Order internal filledOrder;
    IBaseEscrow.Immutables internal immutables;
    NativeOrderEscrow internal escrow;
    bytes32 internal filledOrderHash;

    function setUp() public {
        weth = new WETHMock();
        dai = new TokenMock("DAI", "DAI");
        accessToken = new TokenMock("Resolver Access", "RAT");
        router = new SwapVMRouter(address(0), address(weth), address(this), "SwapVM", "1.0.0");
        factory = new NativeOrderEscrowFactory(
            ISwapVM(address(router)),
            IWETH(address(weth)),
            IERC20(address(accessToken)),
            RESCUE_DELAY
        );

        maker = makeAddr("maker");
        resolver = makeAddr("resolver");
        vm.deal(maker, 100 ether);
        vm.deal(address(this), 100 ether);
        accessToken.mint(resolver, 1);

        dai.mint(address(this), 1e30);
        dai.approve(address(router), type(uint256).max);

        // The program must sell WETH: tokenOut = WETH regardless of sort order
        isAToB = address(dai) < address(weth);
    }

    // === Fills ===

    function test_HappyPath_FullFill_ExactOut() public {
        _createEscrow(_defaultProgram());

        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT, "Escrow holds the wrapped deposit");
        assertEq(address(escrow).balance, 0, "No stray native balance");

        (uint256 amountIn, uint256 amountOut,) = router.swap(filledOrder, WETH_AMOUNT, _takerData(false, true));

        assertEq(amountOut, WETH_AMOUNT, "Taker receives the full WETH deposit");
        assertEq(amountIn, DAI_AMOUNT, "Taker pays the full ask");
        assertEq(weth.balanceOf(address(this)), WETH_AMOUNT, "WETH pulled from the escrow to the taker");
        assertEq(dai.balanceOf(maker), DAI_AMOUNT, "Buy token goes to the real maker, not the clone");
        assertEq(weth.balanceOf(address(escrow)), 0, "Escrow is drained");
        assertEq(dai.balanceOf(address(escrow)), 0, "Nothing stranded on the clone");
    }

    function test_HappyPath_FullFill_ExactIn() public {
        _createEscrow(_defaultProgram());

        (uint256 amountIn, uint256 amountOut,) = router.swap(filledOrder, DAI_AMOUNT, _takerData(true, true));

        assertEq(amountIn, DAI_AMOUNT);
        assertEq(amountOut, WETH_AMOUNT);
        assertEq(dai.balanceOf(maker), DAI_AMOUNT);
        assertEq(weth.balanceOf(address(this)), WETH_AMOUNT);
    }

    function test_PartialFills_ThenCancelRemainder() public {
        _createEscrow(_defaultProgram());

        router.swap(filledOrder, 0.4 ether, _takerData(false, true));
        router.swap(filledOrder, 0.35 ether, _takerData(false, true));

        assertEq(weth.balanceOf(address(this)), 0.75 ether, "Two partial fills delivered");
        assertEq(weth.balanceOf(address(escrow)), 0.25 ether, "Remainder still escrowed");
        assertEq(dai.balanceOf(maker), 2250e18, "Maker paid pro-rata at the order rate");

        uint256 makerEthBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(immutables);

        assertEq(maker.balance - makerEthBefore, 0.25 ether, "Remainder refunded as native ETH");
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_Quote_WorksOnFilledOrder() public {
        _createEscrow(_defaultProgram());

        (uint256 quotedIn, uint256 quotedOut,) = router.asView().quote(filledOrder, WETH_AMOUNT, _takerData(false, true));

        assertEq(quotedIn, DAI_AMOUNT);
        assertEq(quotedOut, WETH_AMOUNT);
    }

    function test_Fill_AfterProgramDeadline_Reverts() public {
        _createEscrow(_defaultProgram());
        uint256 deadline = block.timestamp + EXPIRY_OFFSET;

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Deadline.DeadlineReached.selector, deadline));
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false, true));
    }

    // === Cancellation ===

    function test_Cancel_BeforeFill_RefundsAndBlocksFills() public {
        _createEscrow(_defaultProgram());

        uint256 makerEthBefore = maker.balance;
        vm.prank(maker);
        escrow.cancel(immutables);
        assertEq(maker.balance - makerEthBefore, WETH_AMOUNT, "Full deposit refunded as native ETH");

        // The clone has no WETH left: the router's transferFrom fails
        vm.expectRevert();
        router.swap(filledOrder, WETH_AMOUNT, _takerData(false, true));
    }

    function test_Cancel_OnlyMaker() public {
        _createEscrow(_defaultProgram());

        vm.expectRevert(IBaseEscrow.InvalidCaller.selector);
        escrow.cancel(immutables);
    }

    function test_PublicCancel_GatingAndReward() public {
        _createEscrow(_defaultProgram());

        // Too early: still in the maker-only window
        vm.prank(resolver);
        vm.expectRevert(IBaseEscrow.InvalidTime.selector);
        escrow.publicCancel(immutables, type(uint256).max);

        vm.warp(block.timestamp + PUBLIC_CANCEL_OFFSET);

        // Caller without the access token is rejected
        vm.expectRevert(IBaseEscrow.InvalidCaller.selector);
        escrow.publicCancel(immutables, type(uint256).max);

        // Resolver garbage-collects for a base-fee-capped reward, remainder refunds the maker
        vm.fee(10 gwei);
        uint256 expectedReward = 10 gwei * 120_000 * 110 / 100;
        uint256 makerEthBefore = maker.balance;

        vm.prank(resolver);
        escrow.publicCancel(immutables, type(uint256).max);

        assertEq(resolver.balance, expectedReward, "Resolver reward is basefee * gas budget * premium");
        assertEq(maker.balance - makerEthBefore, WETH_AMOUNT - expectedReward, "Maker gets the remainder");
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_PublicCancel_ZeroRewardLimit_IsAltruistic() public {
        _createEscrow(_defaultProgram());
        vm.warp(block.timestamp + PUBLIC_CANCEL_OFFSET);
        vm.fee(10 gwei);

        uint256 makerEthBefore = maker.balance;
        vm.prank(resolver);
        escrow.publicCancel(immutables, 0);

        assertEq(resolver.balance, 0, "No reward requested");
        assertEq(maker.balance - makerEthBefore, WETH_AMOUNT, "Full deposit refunded");
    }

    // === Signature validation ===

    function test_IsValidSignature_AcceptsCommittedOrder() public {
        _createEscrow(_defaultProgram());

        bytes4 magic = escrow.isValidSignature(filledOrderHash, abi.encode(immutables, makerOrder));
        assertTrue(magic == ERC1271_MAGIC, "ERC-1271 magic value returned");
    }

    function test_IsValidSignature_TamperedImmutables_Reverts() public {
        _createEscrow(_defaultProgram());

        IBaseEscrow.Immutables memory tampered = immutables;
        tampered.amount += 1;

        vm.expectRevert(IBaseEscrow.InvalidImmutables.selector);
        escrow.isValidSignature(filledOrderHash, abi.encode(tampered, makerOrder));
    }

    function test_IsValidSignature_TamperedOrder_Reverts() public {
        _createEscrow(_defaultProgram());

        ISwapVM.Order memory tampered = makerOrder;
        tampered.data[tampered.data.length - 1] = tampered.data[tampered.data.length - 1] ^ bytes1(0xff);

        vm.expectRevert(NativeOrderEscrow.MakerOrderMismatch.selector);
        escrow.isValidSignature(filledOrderHash, abi.encode(immutables, tampered));
    }

    function test_IsValidSignature_WrongFilledHash_Reverts() public {
        _createEscrow(_defaultProgram());

        vm.expectRevert(NativeOrderEscrow.FilledOrderMismatch.selector);
        escrow.isValidSignature(bytes32(uint256(1)), abi.encode(immutables, makerOrder));
    }

    function test_Swap_TamperedImmutables_RevertsBadSignature() public {
        _createEscrow(_defaultProgram());

        IBaseEscrow.Immutables memory tampered = immutables;
        tampered.amount += 1;
        bytes memory signature = abi.encode(tampered, makerOrder);

        vm.expectRevert(abi.encodeWithSelector(
            OrderRegistrator.BadSignature.selector, address(escrow), filledOrderHash, signature
        ));
        router.swap(filledOrder, WETH_AMOUNT, _takerDataWithSignature(false, signature));
    }

    // === Factory ===

    function test_Create_Guards() public {
        ISwapVM.Order memory order = _buildOrder(maker, _defaultProgram());

        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderZeroDeposit.selector);
        factory.create{ value: 0 }(order, _defaultTimelocks());

        // Caller is not the order maker
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderOnlyMakerCanCreate.selector);
        factory.create{ value: 1 ether }(order, _defaultTimelocks());

        // Aqua orders have no signature path, escrow cannot act as maker
        ISwapVM.Order memory aquaOrder = _buildAquaOrder(_defaultProgram());
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderAquaNotSupported.selector);
        factory.create{ value: 1 ether }(aquaOrder, _defaultTimelocks());

        // Unset receiver would default to the clone after maker-patching
        ISwapVM.Order memory noReceiver = _buildOrder(maker, address(0), _defaultProgram());
        vm.prank(maker);
        vm.expectRevert(NativeOrderEscrowFactory.NativeOrderExplicitReceiverRequired.selector);
        factory.create{ value: 1 ether }(noReceiver, _defaultTimelocks());
    }

    function test_Create_DuplicateReverts_SaltDifferentiates() public {
        _createEscrow(_defaultProgram());
        address firstEscrow = address(escrow);

        // Identical order in the same block produces identical immutables => same CREATE2 address
        vm.prank(maker);
        vm.expectRevert();
        factory.create{ value: WETH_AMOUNT }(makerOrder, _defaultTimelocks());

        // A Salt instruction changes the order hash => fresh escrow
        _createEscrow(bytes.concat(Salt.build(uint64(1)), _defaultProgram()));
        assertTrue(address(escrow) != firstEscrow, "Salted order deploys a distinct clone");
        assertEq(weth.balanceOf(address(escrow)), WETH_AMOUNT);
    }

    function test_Create_AddressAndHashConsistency() public {
        _createEscrow(_defaultProgram());

        assertEq(factory.addressOfEscrow(immutables), address(escrow), "CREATE2 address matches immutables");
        assertEq(router.hash(filledOrder), filledOrderHash, "Filled order hash matches factory return");
        assertEq(immutables.orderHash, router.hash(makerOrder), "Immutables commit to the pre-patch hash");
        assertEq(immutables.amount, WETH_AMOUNT);
    }

    // === Rescue ===

    function test_RescueFunds_AfterDelay() public {
        _createEscrow(_defaultProgram());
        dai.mint(address(escrow), 123e18);

        vm.prank(maker);
        vm.expectRevert(IBaseEscrow.InvalidTime.selector);
        escrow.rescueFunds(address(dai), 123e18, immutables);

        vm.warp(block.timestamp + RESCUE_DELAY);

        // Still maker-only
        vm.expectRevert(IBaseEscrow.InvalidCaller.selector);
        escrow.rescueFunds(address(dai), 123e18, immutables);

        vm.prank(maker);
        escrow.rescueFunds(address(dai), 123e18, immutables);
        assertEq(dai.balanceOf(maker), 123e18, "Stray tokens rescued to the maker");
    }

    // === Helpers ===

    function _tokenA() private view returns (address) {
        return address(dai) < address(weth) ? address(dai) : address(weth);
    }

    function _tokenB() private view returns (address) {
        return address(dai) < address(weth) ? address(weth) : address(dai);
    }

    function _defaultProgram() private view returns (bytes memory) {
        return bytes.concat(
            Deadline.build(uint40(block.timestamp + EXPIRY_OFFSET)),
            StaticBalances.build(DAI_AMOUNT, WETH_AMOUNT),
            InvalidateTokenOut.build(),
            LimitSwap.build(address(dai), address(weth))
        );
    }

    function _defaultTimelocks() private pure returns (Timelocks) {
        return Timelocks.wrap(
            (uint256(EXPIRY_OFFSET) << (uint256(TimelocksLib.Stage.SrcCancellation) * 32)) |
            (uint256(PUBLIC_CANCEL_OFFSET) << (uint256(TimelocksLib.Stage.SrcPublicCancellation) * 32))
        );
    }

    function _buildOrder(address orderMaker, bytes memory program) private view returns (ISwapVM.Order memory) {
        return _buildOrder(orderMaker, maker, program);
    }

    function _buildOrder(address orderMaker, address receiver, bytes memory program) private view returns (ISwapVM.Order memory) {
        MakerTraitsLib.Args memory args;
        args.maker = orderMaker;
        args.receiver = receiver;
        args.tokenA = _tokenA();
        args.tokenB = _tokenB();
        args.program = program;
        return MakerTraitsLib.build(args);
    }

    function _buildAquaOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        MakerTraitsLib.Args memory args;
        args.maker = maker;
        args.receiver = maker;
        args.tokenA = _tokenA();
        args.tokenB = _tokenB();
        args.useAquaInsteadOfSignature = true;
        args.program = program;
        return MakerTraitsLib.build(args);
    }

    function _createEscrow(bytes memory program) internal {
        makerOrder = _buildOrder(maker, program);
        vm.prank(maker);
        (address escrowAddr, bytes32 fHash, IBaseEscrow.Immutables memory imm) =
            factory.create{ value: WETH_AMOUNT }(makerOrder, _defaultTimelocks());

        escrow = NativeOrderEscrow(payable(escrowAddr));
        filledOrderHash = fHash;
        immutables = imm;
        filledOrder = makerOrder;
        filledOrder.maker = escrowAddr;
    }

    function _takerData(bool isExactIn, bool allowPartialFill) private view returns (bytes memory) {
        return _takerData(isExactIn, allowPartialFill, abi.encode(immutables, makerOrder));
    }

    function _takerDataWithSignature(bool isExactIn, bytes memory signature) private view returns (bytes memory) {
        return _takerData(isExactIn, true, signature);
    }

    function _takerData(bool isExactIn, bool allowPartialFill, bytes memory signature) private view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.isExactIn = isExactIn;
        args.isAToB = isAToB;
        args.allowPartialFill = allowPartialFill;
        args.to = address(this);
        args.signature = signature;
        return TakerTraitsLib.build(args);
    }

    receive() external payable {}
}
