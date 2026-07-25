// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20, SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";
import { MockTakerBrokenCallback } from "./mocks/MockTakerBrokenCallback.sol";
import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";

import { SwapVM } from "../src/SwapVM.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { Context } from "../src/libs/VM.sol";
import { Fee, FeeArgsBuilder, BPS } from "../src/instructions/Fee.sol";
import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

/// @notice The Aqua protocol-fee-on-amountIn opcodes pull the fee from the maker inside runLoop, before
///         SwapVM credits the taker's tokenIn, so the fee is payable only out of inventory the maker
///         already holds. Collection is therefore best-effort: a maker who cannot cover it does not pay,
///         the swap goes through, and the uncollected fee stays with the maker because pricing is not
///         adjusted. These tests pin that down, and above all pin the one piece of accounting
///         (`amountNetPulled`) that decides whether the maker or the taker ends up with an uncollected fee.
contract AquaProtocolFeeSkipTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    /// @dev 1% in the 1e9 scale used by the fee instructions
    uint32 internal constant PROTOCOL_FEE_BPS = 0.01e9;

    /// @dev The reported case: a position left with dust on the tokenIn side
    uint256 internal constant THIN_BALANCE_IN = 0.01e18;
    uint256 internal constant DEEP_BALANCE_OUT = 20_000_000e18;

    /// @dev Largest amountIn whose fee still fits inside THIN_BALANCE_IN, i.e. the ceiling a two-sided
    ///      position used to be capped at
    uint256 internal constant MAX_PAYABLE_IN = THIN_BALANCE_IN * BPS / PROTOCOL_FEE_BPS;

    uint256 internal constant PRICE_MIN = 1e18;
    uint256 internal constant PRICE_MAX = 4e18;

    uint256 internal constant SWAP_AMOUNT = 10e18;

    ProtocolFeeProviderMock internal feeProvider;

    function setUp() public virtual override {
        super.setUp();
        feeProvider = new ProtocolFeeProviderMock(PROTOCOL_FEE_BPS, protocolFeeRecipient, address(this));
    }

    // ===== HELPERS =====

    function _setup(uint256 balanceA, uint256 balanceB, SwapType swapType) internal view returns (MakerSetup memory) {
        return MakerSetup({
            balanceA: balanceA,
            balanceB: balanceB,
            priceMin: PRICE_MIN,
            priceMax: PRICE_MAX,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            feeInBps: 0,
            protocolFeeRecipient: protocolFeeRecipient,
            swapType: swapType
        });
    }

    /// @dev Ships the strategy and funds the maker's wallet so it actually backs the Aqua ledger
    function _ship(MakerSetup memory setup) internal returns (ISwapVM.Order memory order, bytes32 strategyHash) {
        order = createStrategy(setup);
        strategyHash = shipStrategy(order, tokenA, tokenB, setup.balanceA, setup.balanceB);
        tokenA.mint(maker, setup.balanceA);
        tokenB.mint(maker, setup.balanceB);
    }

    function _shipProgram(
        bytes memory program,
        uint256 balanceA,
        uint256 balanceB
    ) internal returns (ISwapVM.Order memory order, bytes32 strategyHash) {
        order = createStrategy(program);
        strategyHash = shipStrategy(order, tokenA, tokenB, balanceA, balanceB);
        tokenA.mint(maker, balanceA);
        tokenB.mint(maker, balanceB);
    }

    /// @dev buildProgram only wires the static Aqua fee opcode, so variants get assembled here
    function _feeProgram(
        function(Context memory, bytes calldata) internal feeInstruction,
        bytes memory feeArgs,
        bool concentrated
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(feeInstruction, feeArgs),
            concentrated
                ? p.build(
                    XYCConcentrate._xycConcentrateGrowLiquidity2D,
                    XYCConcentrateArgsBuilder.build2D(Math.sqrt(PRICE_MIN * ONE), Math.sqrt(PRICE_MAX * ONE))
                )
                : bytes(""),
            p.build(XYCSwap._xycSwapXD),
            p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
        );
    }

    /// @dev tokenA in, tokenB out
    function _swapProgram(uint256 amount, bool isExactIn) internal view returns (SwapProgram memory) {
        return SwapProgram({
            amount: amount,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: true,
            isExactIn: isExactIn
        });
    }

    /// @dev A taker that pre-pushes an exact amount of its choosing, to probe the pre-push check
    function _prePushTaker(uint256 fundAmount, uint256 pushAmount) internal returns (MockTakerBrokenCallback brokenTaker) {
        brokenTaker = new MockTakerBrokenCallback(aqua, swapVM, address(this));
        brokenTaker.setBehavior(MockTakerBrokenCallback.CallbackBehavior.InsufficientPush);
        brokenTaker.setPushAmountOverride(pushAmount);
        tokenA.mint(address(brokenTaker), fundAmount);
    }

    function _prePushSwap(MockTakerBrokenCallback brokenTaker, ISwapVM.Order memory order, uint256 amount) internal {
        brokenTaker.swap(order, address(tokenA), address(tokenB), amount, takerData(address(brokenTaker), true));
    }

    function _countSkipEvents(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ProtocolFeeSkipped.selector) {
                count++;
            }
        }
    }

    // ===== LIVENESS: THE REPORTED BUG =====

    /// @notice A position holding only tokenB sits at the top of its range and sells tokenB for tokenA. It
    ///         never holds tokenA, so the fee pull underflows its Aqua balance. It used to revert on every
    ///         swap; now the fee is skipped and the swap goes through.
    function test_SingleSidedPosition_FeeSkipped_SwapSucceeds() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(0, INITIAL_BALANCE_B, SwapType.CONCENTRATE_GROW_LIQUIDITY));

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);
        assertGt(quotedOut, 0, "quote prices the swap");

        vm.expectEmit(true, true, true, true, address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, quotedIn * PROTOCOL_FEE_BPS / BPS);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        assertEq(amountIn, quotedIn, "swap consumes the quoted amountIn");
        assertEq(amountOut, quotedOut, "swap delivers the quoted amountOut");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "the whole amountIn lands in the pool, fee included");
    }

    /// @notice The dynamic fee provider variant behaves identically.
    function test_SingleSidedPosition_DynamicFeeProvider_FeeSkipped() public {
        bytes memory program = _feeProgram(
            Fee._aquaDynamicProtocolFeeAmountInXD,
            FeeArgsBuilder.buildDynamicProtocolFee(address(feeProvider)),
            true
        );
        (ISwapVM.Order memory order, bytes32 strategyHash) = _shipProgram(program, 0, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectEmit(true, true, true, true, address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, SWAP_AMOUNT * PROTOCOL_FEE_BPS / BPS);
        swap(swapProgram, order);

        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "dynamic provider fee is skipped too");
    }

    /// @notice ExactOut takes the other branch of _feeAmountIn, where the fee is added on after the curve.
    function test_SingleSidedPosition_ExactOut_FeeSkipped() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(0, INITIAL_BALANCE_B, SwapType.CONCENTRATE_GROW_LIQUIDITY));

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, false);
        (uint256 quotedIn,) = quote(swapProgram, order);
        mintTokenInToTaker(swapProgram, quotedIn);

        vm.recordLogs();
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        assertEq(_countSkipEvents(vm.getRecordedLogs()), 1, "the fee is reported as skipped");
        assertEq(amountOut, SWAP_AMOUNT, "taker gets the exact output it asked for");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "the whole amountIn lands in the pool, fee included");
    }

    /// @notice A two-sided position used to be capped at `balanceIn * BPS / feeBps` per swap. Past that
    ///         ceiling the fee no longer fits in the tokenIn side, and the swap now proceeds without it.
    function test_ThinTokenInSide_AboveOldCeiling_FeeSkipped() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(THIN_BALANCE_IN, DEEP_BALANCE_OUT, SwapType.XYC));

        uint256 amount = MAX_PAYABLE_IN + 0.1e18;
        SwapProgram memory swapProgram = _swapProgram(amount, true);
        mintTokenInToTaker(swapProgram);

        vm.expectEmit(true, true, true, true, address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, amount * PROTOCOL_FEE_BPS / BPS);
        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(amountIn, amount, "taker pays the full amountIn");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");
    }

    // ===== NO REGRESSION WHERE THE FEE WAS ALREADY COLLECTIBLE =====

    /// @notice Right at the ceiling nothing changes: the fee is still collected in full.
    function test_ThinTokenInSide_AtCeiling_FeeStillCollected() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(THIN_BALANCE_IN, DEEP_BALANCE_OUT, SwapType.XYC));

        SwapProgram memory swapProgram = _swapProgram(MAX_PAYABLE_IN, true);
        mintTokenInToTaker(swapProgram);

        vm.recordLogs();
        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(_countSkipEvents(vm.getRecordedLogs()), 0, "nothing is skipped");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), THIN_BALANCE_IN, "fee drains the whole tokenIn side");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), amountIn * PROTOCOL_FEE_BPS / BPS, "and it is the full fee");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "pool keeps amountIn net of the fee it had pre-funded");
    }

    /// @notice A healthy two-sided position pays the fee in both directions of the exactIn/exactOut split.
    function test_HealthyPosition_FeeCollected_ExactIn() public {
        (ISwapVM.Order memory order,) = _ship(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.recordLogs();
        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(_countSkipEvents(vm.getRecordedLogs()), 0, "nothing is skipped");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), amountIn * PROTOCOL_FEE_BPS / BPS, "fee collected in full");
    }

    function test_HealthyPosition_FeeCollected_ExactOut() public {
        (ISwapVM.Order memory order,) = _ship(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, false);
        (uint256 quotedIn,) = quote(swapProgram, order);
        mintTokenInToTaker(swapProgram, quotedIn);

        vm.recordLogs();
        (uint256 amountIn,) = swap(swapProgram, order);

        assertEq(_countSkipEvents(vm.getRecordedLogs()), 0, "nothing is skipped");
        assertGt(tokenA.balanceOf(protocolFeeRecipient), 0, "fee collected");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), amountIn * PROTOCOL_FEE_BPS / BPS, "fee collected in full");
    }

    // ===== WHERE AN UNCOLLECTED FEE ENDS UP =====

    /// @notice Pricing is untouched when the fee is skipped, so the taker is still charged for it. This
    ///         pins where it lands: with the maker. The behaviour is an accepted product tradeoff, so it is
    ///         asserted explicitly rather than left to drift.
    function test_SkippedFee_TakerPaysQuotedPrice_MakerKeepsTheFee() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(THIN_BALANCE_IN, DEEP_BALANCE_OUT, SwapType.XYC));

        SwapProgram memory swapProgram = _swapProgram(MAX_PAYABLE_IN + 0.1e18, true);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        uint256 fee = amountIn * PROTOCOL_FEE_BPS / BPS;
        uint256 netAmountIn = amountIn - fee;
        uint256 pricedOut = netAmountIn * DEEP_BALANCE_OUT / (THIN_BALANCE_IN + netAmountIn);

        assertGt(fee, THIN_BALANCE_IN, "the fee is larger than the tokenIn side, so it cannot be collected");
        assertEq(amountOut, pricedOut, "the taker is priced as if the fee had been taken");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "no partial collection, the whole fee is dropped");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, THIN_BALANCE_IN + amountIn, "the maker keeps the fee the recipient did not get");
    }

    // ===== amountNetPulled: THE TAKER ALWAYS OWES THE FULL amountIn =====

    /// @notice The failure mode to avoid. amountNetPulled reports how much tokenIn the program already took
    ///         out of the maker's ledger; crediting it for a pull that never happened would drop the
    ///         pre-push requirement to amountIn - fee and hand the fee to the taker instead of the maker.
    ///         Note the trailing zero in the revert args: nothing was pulled, so nothing is discounted.
    function test_SkippedFee_PrePushShortByTheFee_Reverts() public {
        (ISwapVM.Order memory order,) = _ship(_setup(0, INITIAL_BALANCE_B, SwapType.CONCENTRATE_GROW_LIQUIDITY));

        uint256 fee = SWAP_AMOUNT * PROTOCOL_FEE_BPS / BPS;
        MockTakerBrokenCallback brokenTaker = _prePushTaker(SWAP_AMOUNT, SWAP_AMOUNT - fee);

        vm.expectRevert(abi.encodeWithSelector(
            SwapVM.AquaBalanceInsufficientAfterTakerPush.selector,
            SWAP_AMOUNT - fee, // balance after the short push
            0,                 // original balance: a one-sided position holds no tokenIn
            SWAP_AMOUNT,       // amountIn the taker owes
            0                  // amountNetPulled: the skipped pull discounts nothing
        ));
        _prePushSwap(brokenTaker, order, SWAP_AMOUNT);
    }

    /// @notice One fee more than the short push and the same swap settles.
    function test_SkippedFee_PrePushOfTheFullAmountIn_Passes() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(0, INITIAL_BALANCE_B, SwapType.CONCENTRATE_GROW_LIQUIDITY));

        MockTakerBrokenCallback brokenTaker = _prePushTaker(SWAP_AMOUNT, SWAP_AMOUNT);
        _prePushSwap(brokenTaker, order, SWAP_AMOUNT);

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, SWAP_AMOUNT, "pool receives the full amountIn");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "and the fee was skipped");
    }

    /// @notice A collected fee does not discount the taker either. Same requirement, and the only
    ///         difference from the skipped case is the amountNetPulled field of the revert.
    function test_CollectedFee_PrePushShortByTheFee_Reverts() public {
        (ISwapVM.Order memory order,) = _ship(_setup(THIN_BALANCE_IN, DEEP_BALANCE_OUT, SwapType.XYC));

        uint256 fee = MAX_PAYABLE_IN * PROTOCOL_FEE_BPS / BPS;
        MockTakerBrokenCallback brokenTaker = _prePushTaker(MAX_PAYABLE_IN, MAX_PAYABLE_IN - fee);

        vm.expectRevert(abi.encodeWithSelector(
            SwapVM.AquaBalanceInsufficientAfterTakerPush.selector,
            MAX_PAYABLE_IN - fee, // fee pulled the ledger to zero, then the short push
            THIN_BALANCE_IN,      // original balance
            MAX_PAYABLE_IN,       // amountIn the taker owes
            fee                   // amountNetPulled: the pull landed
        ));
        _prePushSwap(brokenTaker, order, MAX_PAYABLE_IN);
    }

    /// @notice OpenZeppelin M-04 / Theori #10 stay fixed: with the fee collected mid-swap, pushing exactly
    ///         amountIn is still enough. Without amountNetPulled the taker would owe amountIn + fee.
    function test_CollectedFee_PrePushOfTheFullAmountIn_Passes() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(THIN_BALANCE_IN, DEEP_BALANCE_OUT, SwapType.XYC));

        uint256 fee = MAX_PAYABLE_IN * PROTOCOL_FEE_BPS / BPS;
        MockTakerBrokenCallback brokenTaker = _prePushTaker(MAX_PAYABLE_IN, MAX_PAYABLE_IN);
        _prePushSwap(brokenTaker, order, MAX_PAYABLE_IN);

        assertEq(tokenA.balanceOf(protocolFeeRecipient), fee, "fee collected");
        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, THIN_BALANCE_IN + MAX_PAYABLE_IN - fee, "ledger nets out to amountIn minus the fee");
    }

    // ===== QUOTE/SWAP CONSISTENCY =====

    function test_QuoteMatchesSwap_WhenFeeIsSkipped() public {
        (ISwapVM.Order memory order,) = _ship(_setup(0, INITIAL_BALANCE_B, SwapType.CONCENTRATE_GROW_LIQUIDITY));

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        assertEq(amountIn, quotedIn, "amountIn matches the quote");
        assertEq(amountOut, quotedOut, "amountOut matches the quote");
    }

    function test_QuoteMatchesSwap_WhenFeeIsCollected() public {
        (ISwapVM.Order memory order,) = _ship(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        assertEq(amountIn, quotedIn, "amountIn matches the quote");
        assertEq(amountOut, quotedOut, "amountOut matches the quote");
    }

    /// @notice The emit sits behind the isStaticContext guard, so quoting stays free of side effects.
    function test_Quote_MovesNothingAndEmitsNothing() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));

        vm.recordLogs();
        quote(_swapProgram(SWAP_AMOUNT, true), order);

        assertEq(_countSkipEvents(vm.getRecordedLogs()), 0, "quote emits no skip event");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "quote never moves the fee");
        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, INITIAL_BALANCE_A, "quote leaves the ledger untouched");
    }

    // ===== WHAT THE CATCH ACTUALLY SWALLOWS =====

    /// @notice Aqua balances are allowances over the maker's wallet, so a funded ledger with an unfunded
    ///         wallet fails in the token leg rather than the ledger underflow. Also skipped.
    function test_MakerWalletShort_FeeSkipped() public {
        ISwapVM.Order memory order = createStrategy(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, INITIAL_BALANCE_A, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B); // only the tokenOut side is actually funded

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectEmit(true, true, true, true, address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, SWAP_AMOUNT * PROTOCOL_FEE_BPS / BPS);
        swap(swapProgram, order);

        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");
    }

    function test_MakerAquaAllowanceRevoked_FeeSkipped() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));

        vm.prank(maker);
        tokenA.approve(address(aqua), 0);

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectEmit(true, true, true, true, address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, SWAP_AMOUNT * PROTOCOL_FEE_BPS / BPS);
        swap(swapProgram, order);

        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");
    }

    /// @notice The skip is not only maker-triggered. A blacklisting token refusing the fee recipient
    ///         silently stops collection for every strategy trading that token, which is why
    ///         ProtocolFeeSkipped has to be monitored.
    function test_RecipientBlockedByToken_FeeSkipped() public {
        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(INITIAL_BALANCE_A, INITIAL_BALANCE_B, SwapType.XYC));

        uint256 fee = SWAP_AMOUNT * PROTOCOL_FEE_BPS / BPS;
        vm.mockCallRevert(
            address(tokenA),
            abi.encodeCall(IERC20.transferFrom, (maker, protocolFeeRecipient, fee)),
            abi.encodeWithSignature("Error(string)", "Blacklisted")
        );

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectEmit(true, true, true, true, address(swapVM));
        emit ProtocolFeeSkipped(strategyHash, address(tokenA), protocolFeeRecipient, fee);
        swap(swapProgram, order);

        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "recipient is paid nothing");
    }

    /// @notice A zero fee is not a skipped fee, so it must not pollute the monitoring signal. The pull is
    ///         not even attempted: tokenA is made to reject zero-value transfers, which is a real ERC20
    ///         behaviour that would otherwise turn every swap on a zero-fee strategy into a skip event.
    function test_ZeroFeeBps_DoesNotPullAndEmitsNothing() public {
        bytes memory program = _feeProgram(
            Fee._aquaProtocolFeeAmountInXD,
            FeeArgsBuilder.buildProtocolFee(0, protocolFeeRecipient),
            false
        );
        (ISwapVM.Order memory order,) = _shipProgram(program, INITIAL_BALANCE_A, INITIAL_BALANCE_B);

        vm.mockCallRevert(
            address(tokenA),
            abi.encodeCall(IERC20.transferFrom, (maker, protocolFeeRecipient, 0)),
            abi.encodeWithSignature("Error(string)", "zero value transfer")
        );

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.recordLogs();
        swap(swapProgram, order);

        assertEq(_countSkipEvents(vm.getRecordedLogs()), 0, "a zero fee is not a skipped fee");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), 0, "nothing to collect");
    }

    /// @notice A fee that names no recipient can never be paid, which is a configuration error rather than
    ///         a maker who is temporarily short. It must fail loudly instead of disappearing into the skip
    ///         path on every swap forever.
    function test_ZeroRecipient_Reverts() public {
        bytes memory program = _feeProgram(
            Fee._aquaProtocolFeeAmountInXD,
            FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, address(0)),
            false
        );
        (ISwapVM.Order memory order,) = _shipProgram(program, INITIAL_BALANCE_A, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectRevert(Fee.FeeDynamicProtocolInvalidRecipient.selector);
        swap(swapProgram, order);
    }

    // ===== BLAST RADIUS: THE WALLET-CHARGING OPCODES ARE UNCHANGED =====

    /// @notice Only the Aqua variants gained a skip path. The wallet-charging opcodes go through SafeERC20,
    ///         which try/catch cannot wrap, and they still revert when the maker cannot pay.
    function test_WalletFeeOpcode_StillReverts() public {
        bytes memory program = _feeProgram(
            Fee._protocolFeeAmountInXD,
            FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient),
            true
        );
        (ISwapVM.Order memory order,) = _shipProgram(program, 0, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swap(swapProgram, order);
    }

    function test_DynamicWalletFeeOpcode_StillReverts() public {
        bytes memory program = _feeProgram(
            Fee._dynamicProtocolFeeAmountInXD,
            FeeArgsBuilder.buildDynamicProtocolFee(address(feeProvider)),
            true
        );
        (ISwapVM.Order memory order,) = _shipProgram(program, 0, INITIAL_BALANCE_B);

        SwapProgram memory swapProgram = _swapProgram(SWAP_AMOUNT, true);
        mintTokenInToTaker(swapProgram);

        vm.expectRevert(SafeERC20.SafeTransferFromFailed.selector);
        swap(swapProgram, order);
    }

    // ===== PROPERTY =====

    /// @notice Whatever the tokenIn side holds, the swap settles, collection is all or nothing, and the
    ///         maker's ledger gains exactly the amountIn minus whatever was actually collected.
    function testFuzz_FeeIsAllOrNothing(uint256 balanceIn, uint256 amountIn) public {
        balanceIn = bound(balanceIn, 0, 10e18);
        amountIn = bound(amountIn, 1e15, 100e18);

        (ISwapVM.Order memory order, bytes32 strategyHash) =
            _ship(_setup(balanceIn, DEEP_BALANCE_OUT, SwapType.CONCENTRATE_GROW_LIQUIDITY));

        SwapProgram memory swapProgram = _swapProgram(amountIn, true);
        mintTokenInToTaker(swapProgram);

        (uint256 actualIn,) = swap(swapProgram, order);

        uint256 collected = tokenA.balanceOf(protocolFeeRecipient);
        assertTrue(
            collected == 0 || collected == actualIn * PROTOCOL_FEE_BPS / BPS,
            "collection is all or nothing, never partial"
        );

        (uint256 finalBalanceA,) = getAquaBalances(strategyHash);
        assertEq(finalBalanceA, balanceIn + actualIn - collected, "ledger gains amountIn minus what was collected");
    }
}
