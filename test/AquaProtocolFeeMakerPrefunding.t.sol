// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { BPS, FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { ProtocolFeeProviderMock } from "../mocks/ProtocolFeeProviderMock.sol";
import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";

/// @notice Protocol-fee-on-amountIn is settled after the transfer phase, out of the tokenIn the taker
///         delivers. These tests cover the cases that used to require the maker to pre-fund tokenIn: a
///         single-sided position holding none of it, and a position whose tokenIn side is far thinner
///         than the fee on the trade being priced.
contract AquaProtocolFeeMakerPrefundingTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    /// @dev 1% in the 1e9 scale used by the fee instructions
    uint32 internal constant PROTOCOL_FEE_BPS = 0.01e9;

    /// @dev Kirill's example from the report: a position left with dust on the tokenIn side
    uint256 internal constant THIN_BALANCE_IN = 0.01e18;
    uint256 internal constant DEEP_BALANCE_OUT = 20_000_000e18;

    /// @dev Largest amountIn whose fee fits into THIN_BALANCE_IN, i.e. the old per-swap ceiling
    uint256 internal constant OLD_TRADE_CEILING = THIN_BALANCE_IN * BPS / PROTOCOL_FEE_BPS;

    /// @dev Concentrated range of [1.0, 4.0] tokenB per tokenA, expressed as sqrt prices in 1e18
    uint256 internal constant SQRT_PRICE_MIN = 1e18;
    uint256 internal constant SQRT_PRICE_MAX = 2e18;

    ProtocolFeeProviderMock public feeProvider;

    function setUp() public virtual override {
        super.setUp();
        feeProvider = new ProtocolFeeProviderMock(PROTOCOL_FEE_BPS, protocolFeeRecipient, address(this));
    }

    function _concentratedProgram(Opcode feeOpcode) internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(feeOpcode, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX))
        );
    }

    function _xycProgram() internal view returns (bytes memory) {
        Program p;
        return bytes.concat(
            p.build(Opcode.AquaProtocolFeeAmountIn, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.XYCSwap)
        );
    }

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

    /// @dev Ships a position that holds tokenB only. It sits at the top of its price range and sells
    ///      tokenB for tokenA, so tokenIn inventory is zero in both the Aqua ledger and the wallet.
    function _shipSingleSided(ISwapVM.Order memory order) internal returns (bytes32 strategyHash) {
        strategyHash = shipStrategy(order, tokenA, tokenB, 0, INITIAL_BALANCE_B);
        tokenB.mint(maker, INITIAL_BALANCE_B);
    }

    function test_SingleSidedPosition_SwapMatchesQuoteAndPaysFee() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.AquaProtocolFeeAmountIn));
        bytes32 strategyHash = _shipSingleSided(order);

        SwapProgram memory swapProgram = _swapProgram(10e18, true);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);
        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);

        assertEq(amountIn, quotedIn, "swap consumes the quoted amountIn");
        assertEq(amountOut, quotedOut, "swap delivers the quoted amountOut");
        assertEq(amountIn, 10e18, "taker pays the requested amountIn");

        uint256 expectedFee = amountIn * PROTOCOL_FEE_BPS / BPS;
        assertEq(tokenA.balanceOf(protocolFeeRecipient), expectedFee, "recipient is paid out of the incoming tokenIn");
        assertEq(tokenA.balanceOf(maker), amountIn - expectedFee, "maker keeps amountIn net of the fee");

        (uint256 balanceA, uint256 balanceB) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn - expectedFee, "ledger tracks the wallet");
        assertEq(balanceB, INITIAL_BALANCE_B - amountOut, "output side pays the taker");
    }

    function test_SingleSidedPosition_ExactOut() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.AquaProtocolFeeAmountIn));
        bytes32 strategyHash = _shipSingleSided(order);

        SwapProgram memory swapProgram = _swapProgram(100e18, false);
        mintTokenInToTaker(swapProgram, 100e18);

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        assertEq(amountOut, 100e18, "taker receives the requested amountOut");

        uint256 expectedFee = amountIn * PROTOCOL_FEE_BPS / BPS;
        assertApproxEqAbs(tokenA.balanceOf(protocolFeeRecipient), expectedFee, 1, "recipient is paid the fee on amountIn");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA + tokenA.balanceOf(protocolFeeRecipient), amountIn, "amountIn splits between pool and recipient");
    }

    function test_SingleSidedPosition_DynamicFee() public {
        Program p;
        bytes memory program = bytes.concat(
            p.build(Opcode.AquaDynamicProtocolFeeAmountIn, FeeArgsBuilder.buildDynamicProtocolFee(address(feeProvider))),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX))
        );

        ISwapVM.Order memory order = createStrategy(program);
        _shipSingleSided(order);

        SwapProgram memory swapProgram = _swapProgram(10e18, true);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);
        assertEq(tokenA.balanceOf(protocolFeeRecipient), amountIn * PROTOCOL_FEE_BPS / BPS, "dynamic fee is paid");
    }

    /// @notice The per-swap ceiling of `balanceIn * BPS / feeBps` is gone: a trade two orders of magnitude
    ///         above it settles against a position whose tokenIn side holds dust.
    function test_ThinTokenInSide_TradesFarAboveOldCeiling() public {
        ISwapVM.Order memory order = createStrategy(_xycProgram());
        bytes32 strategyHash = shipStrategy(order, tokenA, tokenB, THIN_BALANCE_IN, DEEP_BALANCE_OUT);
        tokenA.mint(maker, THIN_BALANCE_IN);
        tokenB.mint(maker, DEEP_BALANCE_OUT);

        SwapProgram memory swapProgram = _swapProgram(100 * OLD_TRADE_CEILING, true);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        uint256 expectedFee = amountIn * PROTOCOL_FEE_BPS / BPS;
        assertGt(expectedFee, THIN_BALANCE_IN, "fee exceeds the tokenIn side the maker started with");
        assertEq(tokenA.balanceOf(protocolFeeRecipient), expectedFee, "recipient is still paid in full");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, THIN_BALANCE_IN + amountIn - expectedFee, "ledger grows by amountIn net of the fee");
    }

    /// @notice Two protocol fee instructions with different recipients both settle.
    function test_MultipleFeeRecipients() public {
        address secondRecipient = vm.addr(0x9999);

        Program p;
        bytes memory program = bytes.concat(
            p.build(Opcode.AquaProtocolFeeAmountIn, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.AquaProtocolFeeAmountIn, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, secondRecipient)),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX))
        );

        ISwapVM.Order memory order = createStrategy(program);
        bytes32 strategyHash = _shipSingleSided(order);

        SwapProgram memory swapProgram = _swapProgram(10e18, true);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        uint256 firstFee = tokenA.balanceOf(protocolFeeRecipient);
        uint256 secondFee = tokenA.balanceOf(secondRecipient);
        assertGt(firstFee, 0, "outer recipient is paid");
        assertGt(secondFee, 0, "inner recipient is paid");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA + firstFee + secondFee, amountIn, "amountIn splits between pool and both recipients");
    }

    /// @notice The same recipient charged twice is settled as a single transfer.
    function test_RepeatedFeeRecipientIsMerged() public {
        Program p;
        bytes memory program = bytes.concat(
            p.build(Opcode.AquaProtocolFeeAmountIn, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.AquaProtocolFeeAmountIn, FeeArgsBuilder.buildProtocolFee(PROTOCOL_FEE_BPS, protocolFeeRecipient)),
            p.build(Opcode.XYCConcentrateSwap, XYCConcentrateArgsBuilder.build2D(SQRT_PRICE_MIN, SQRT_PRICE_MAX))
        );

        ISwapVM.Order memory order = createStrategy(program);
        bytes32 strategyHash = _shipSingleSided(order);

        SwapProgram memory swapProgram = _swapProgram(10e18, true);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA + tokenA.balanceOf(protocolFeeRecipient), amountIn, "both charges reach the recipient");
    }

    /// @notice The non-Aqua fee opcode charges the maker's wallet, which is funded by the same transfer
    ///         phase, so a single-sided position no longer needs a tokenIn working buffer either.
    function test_SingleSidedPosition_WalletFeeOpcode() public {
        ISwapVM.Order memory order = createStrategy(_concentratedProgram(Opcode.ProtocolFeeAmountIn));
        bytes32 strategyHash = _shipSingleSided(order);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);

        SwapProgram memory swapProgram = _swapProgram(10e18, true);
        mintTokenInToTaker(swapProgram);

        (uint256 amountIn,) = swap(swapProgram, order);

        uint256 expectedFee = amountIn * PROTOCOL_FEE_BPS / BPS;
        assertEq(tokenA.balanceOf(protocolFeeRecipient), expectedFee, "recipient is paid from the maker's wallet");
        assertEq(tokenA.balanceOf(maker), amountIn - expectedFee, "wallet holds amountIn net of the fee");

        (uint256 balanceA,) = getAquaBalances(strategyHash);
        assertEq(balanceA, amountIn, "ledger credits the full amountIn and over-states the wallet by the fee");
    }
}
