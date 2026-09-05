// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { StaticBalances, DynamicBalances } from "../../src/instructions/Balances.sol";
import { XYCConcentrateSwap } from "../../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { Decay } from "../../src/instructions/Decay.sol";
import { LimitSwap } from "../../src/instructions/LimitSwap.sol";
import { DutchAuctionBalanceIn, DutchAuctionBalanceOut } from "../../src/instructions/DutchAuction.sol";
import { TWAPSwap } from "../../src/instructions/TWAPSwap.sol";
import { AdjustMinRate } from "../../src/instructions/MinRate.sol";
import { FeeFlatIn, FeeFlatOut } from "../../src/instructions/FeeFlat.sol";
import { Salt, Deadline } from "../../src/instructions/Controls.sol";
import { InvalidateTokenIn, InvalidateBit } from "../../src/instructions/Invalidators.sol";

/// @title Gas
/// @notice Combined AMM + LimitSwap gas benchmarks. Writes AMMGas.json / LimitSwapGas.json.
contract Gas is Test {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant AMM_BALANCE = 1000e18;
    uint256 constant LIMIT_BALANCE_A = 1000e18;
    uint256 constant LIMIT_BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.mint(taker, 1e30);
        tokenB.mint(taker, 1e30);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_gas_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYC(true);
        _snapshotQuote("AMMGas", "XYCSwap_quote_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYC(false);
        _snapshotQuote("AMMGas", "XYCSwap_quote_exactOut", order, takerData);
    }

    function test_gas_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYC(true);
        _snapshotSwap("AMMGas", "XYCSwap_swap_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYC(false);
        _snapshotSwap("AMMGas", "XYCSwap_swap_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateGrowLiquidity(true);
        _snapshotQuote("AMMGas", "ConcentrateGrowLiquidity_XYCSwap_quote_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateGrowLiquidity(false);
        _snapshotQuote("AMMGas", "ConcentrateGrowLiquidity_XYCSwap_quote_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateGrowLiquidity(true);
        _snapshotSwap("AMMGas", "ConcentrateGrowLiquidity_XYCSwap_swap_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateGrowLiquidity(false);
        _snapshotSwap("AMMGas", "ConcentrateGrowLiquidity_XYCSwap_swap_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateGrowPriceRange(true);
        _snapshotQuote("AMMGas", "ConcentrateGrowPriceRange_XYCSwap_quote_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateGrowPriceRange(true);
        _snapshotSwap("AMMGas", "ConcentrateGrowPriceRange_XYCSwap_swap_exactIn", order, takerData);
    }

    function test_gas_Decay_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammDecay(true);
        _snapshotQuote("AMMGas", "Decay_XYCSwap_quote_exactIn", order, takerData);
    }

    function test_gas_Decay_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammDecay(false);
        _snapshotQuote("AMMGas", "Decay_XYCSwap_quote_exactOut", order, takerData);
    }

    function test_gas_Decay_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammDecay(true);
        _snapshotSwap("AMMGas", "Decay_XYCSwap_swap_exactIn", order, takerData);
    }

    function test_gas_Decay_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammDecay(false);
        _snapshotSwap("AMMGas", "Decay_XYCSwap_swap_exactOut", order, takerData);
    }

    function test_gas_Concentrate_Decay_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateDecay(true);
        _snapshotQuote("AMMGas", "Concentrate_Decay_XYCSwap_quote_exactIn", order, takerData);
    }

    function test_gas_Concentrate_Decay_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammConcentrateDecay(true);
        _snapshotSwap("AMMGas", "Concentrate_Decay_XYCSwap_swap_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYCFee(true, true);
        _snapshotQuote("AMMGas", "XYCSwap_FlatFeeIn_quote_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYCFee(true, true);
        _snapshotSwap("AMMGas", "XYCSwap_FlatFeeIn_swap_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeOut_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYCFee(false, true);
        _snapshotQuote("AMMGas", "XYCSwap_FlatFeeOut_quote_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeOut_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammXYCFee(false, true);
        _snapshotSwap("AMMGas", "XYCSwap_FlatFeeOut_swap_exactIn", order, takerData);
    }

    function test_gas_FullAMM_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammFull(true);
        _snapshotQuote("AMMGas", "FullAMM_quote_exactIn", order, takerData);
    }

    function test_gas_FullAMM_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _ammFull(true);
        _snapshotSwap("AMMGas", "FullAMM_swap_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limit(true);
        _snapshotQuote("LimitSwapGas", "LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limit(false);
        _snapshotQuote("LimitSwapGas", "LimitSwap_quote_exactOut", order, takerData);
    }

    function test_gas_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limit(true);
        _snapshotSwap("LimitSwapGas", "LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limit(false);
        _snapshotSwap("LimitSwapGas", "LimitSwap_swap_exactOut", order, takerData);
    }

    function test_gas_DutchAuctionIn_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(true, true);
        _snapshotQuote("LimitSwapGas", "DutchAuctionIn_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_DutchAuctionIn_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(true, false);
        _snapshotQuote("LimitSwapGas", "DutchAuctionIn_LimitSwap_quote_exactOut", order, takerData);
    }

    function test_gas_DutchAuctionIn_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(true, true);
        _snapshotSwap("LimitSwapGas", "DutchAuctionIn_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_DutchAuctionIn_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(true, false);
        _snapshotSwap("LimitSwapGas", "DutchAuctionIn_LimitSwap_swap_exactOut", order, takerData);
    }

    function test_gas_DutchAuctionOut_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(false, true);
        _snapshotQuote("LimitSwapGas", "DutchAuctionOut_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_DutchAuctionOut_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(false, false);
        _snapshotQuote("LimitSwapGas", "DutchAuctionOut_LimitSwap_quote_exactOut", order, takerData);
    }

    function test_gas_DutchAuctionOut_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(false, true);
        _snapshotSwap("LimitSwapGas", "DutchAuctionOut_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_DutchAuctionOut_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDutch(false, false);
        _snapshotSwap("LimitSwapGas", "DutchAuctionOut_LimitSwap_swap_exactOut", order, takerData);
    }

    function test_gas_TWAP_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _limitTWAP(true);
        vm.warp(startTime + 1800);
        _snapshotQuote("LimitSwapGas", "TWAP_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_TWAP_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _limitTWAP(false);
        vm.warp(startTime + 1800);
        _snapshotQuote("LimitSwapGas", "TWAP_LimitSwap_quote_exactOut", order, takerData);
    }

    function test_gas_TWAP_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _limitTWAP(true);
        vm.warp(startTime + 1800);
        _snapshotSwap("LimitSwapGas", "TWAP_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_TWAP_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData, uint256 startTime) = _limitTWAP(false);
        vm.warp(startTime + 1800);
        _snapshotSwap("LimitSwapGas", "TWAP_LimitSwap_swap_exactOut", order, takerData);
    }

    function test_gas_MinRate_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitMinRate(true);
        _snapshotQuote("LimitSwapGas", "MinRate_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_MinRate_LimitSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitMinRate(false);
        _snapshotQuote("LimitSwapGas", "MinRate_LimitSwap_quote_exactOut", order, takerData);
    }

    function test_gas_MinRate_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitMinRate(true);
        _snapshotSwap("LimitSwapGas", "MinRate_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_MinRate_LimitSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitMinRate(false);
        _snapshotSwap("LimitSwapGas", "MinRate_LimitSwap_swap_exactOut", order, takerData);
    }

    function test_gas_LimitSwap_FlatFeeIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitFee(true, true);
        _snapshotQuote("LimitSwapGas", "LimitSwap_FlatFeeIn_quote_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_FlatFeeIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitFee(true, true);
        _snapshotSwap("LimitSwapGas", "LimitSwap_FlatFeeIn_swap_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_FlatFeeOut_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitFee(false, true);
        _snapshotQuote("LimitSwapGas", "LimitSwap_FlatFeeOut_quote_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_FlatFeeOut_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitFee(false, true);
        _snapshotSwap("LimitSwapGas", "LimitSwap_FlatFeeOut_swap_exactIn", order, takerData);
    }

    function test_gas_Deadline_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDeadline(true);
        _snapshotQuote("LimitSwapGas", "Deadline_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_Deadline_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitDeadline(true);
        _snapshotSwap("LimitSwapGas", "Deadline_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_Salt_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitSalt(true);
        _snapshotQuote("LimitSwapGas", "Salt_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_Salt_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitSalt(true);
        _snapshotSwap("LimitSwapGas", "Salt_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_InvalidateBit_LimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitInvalidateBit(true);
        _snapshotQuote("LimitSwapGas", "InvalidateBit_LimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_InvalidateBit_LimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitInvalidateBit(true);
        _snapshotSwap("LimitSwapGas", "InvalidateBit_LimitSwap_swap_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_InvalidateTokenIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitInvalidateTokenIn(true);
        _snapshotQuote("LimitSwapGas", "LimitSwap_InvalidateTokenIn_quote_exactIn", order, takerData);
    }

    function test_gas_LimitSwap_InvalidateTokenIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitInvalidateTokenIn(true);
        _snapshotSwap("LimitSwapGas", "LimitSwap_InvalidateTokenIn_swap_exactIn", order, takerData);
    }

    function test_gas_FullLimitSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitFull(true);
        _snapshotQuote("LimitSwapGas", "FullLimitSwap_quote_exactIn", order, takerData);
    }

    function test_gas_FullLimitSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _limitFull(true);
        _snapshotSwap("LimitSwapGas", "FullLimitSwap_swap_exactIn", order, takerData);
    }

    function _snapshotQuote(
        string memory group,
        string memory name,
        ISwapVM.Order memory order,
        bytes memory takerData
    ) private {
        swapVM.asView().quote(order, SWAP_AMOUNT, takerData);
        vm.snapshotGasLastCall(group, name);
    }

    function _snapshotSwap(
        string memory group,
        string memory name,
        ISwapVM.Order memory order,
        bytes memory takerData
    ) private {
        swapVM.swap(order, SWAP_AMOUNT, takerData);
        vm.snapshotGasLastCall(group, name);
    }

    function _concentrateBalances(uint256 available, uint256 sqrtPmin, uint256 sqrtPmax)
        internal
        view
        returns (uint256 balA, uint256 balB)
    {
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateSwap.computeLiquidityFromAmounts(available, available, 1e18, sqrtPmin, sqrtPmax);
        (balA, balB) = address(tokenA) < address(tokenB) ? (actualLt, actualGt) : (actualGt, actualLt);
    }

    function _ammXYC(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(bytes.concat(DynamicBalances.build(AMM_BALANCE, AMM_BALANCE), XYCSwap.build()), isExactIn);
    }

    function _ammXYCFee(bool isFeeIn, bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        bytes memory fee = isFeeIn ? FeeFlatIn.build(100) : FeeFlatOut.build(100);
        return _order(bytes.concat(DynamicBalances.build(AMM_BALANCE, AMM_BALANCE), fee, XYCSwap.build()), isExactIn);
    }

    function _ammConcentrateGrowLiquidity(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balA, uint256 balB) = _concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return _order(bytes.concat(DynamicBalances.build(balA, balB), XYCConcentrateSwap.build(sqrtPmin, sqrtPmax)), isExactIn);
    }

    function _ammConcentrateGrowPriceRange(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.7e36);
        uint256 sqrtPmax = Math.sqrt(1.4e36);
        (uint256 balA, uint256 balB) = _concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return _order(bytes.concat(DynamicBalances.build(balA, balB), XYCConcentrateSwap.build(sqrtPmin, sqrtPmax)), isExactIn);
    }

    function _ammDecay(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(DynamicBalances.build(AMM_BALANCE, AMM_BALANCE), Decay.build(3600), XYCSwap.build()),
            isExactIn
        );
    }

    function _ammConcentrateDecay(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balA, uint256 balB) = _concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return _order(
            bytes.concat(DynamicBalances.build(balA, balB), Decay.build(3600), XYCConcentrateSwap.build(sqrtPmin, sqrtPmax)),
            isExactIn
        );
    }

    function _ammFull(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balA, uint256 balB) = _concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return _order(
            bytes.concat(
                DynamicBalances.build(balA, balB),
                Decay.build(3600),
                FeeFlatIn.build(30),
                XYCConcentrateSwap.build(sqrtPmin, sqrtPmax)
            ),
            isExactIn
        );
    }

    function _limit(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B), LimitSwap.build(address(tokenA), address(tokenB))),
            isExactIn
        );
    }

    function _limitFee(bool isFeeIn, bool isExactIn)
        private
        view
        returns (ISwapVM.Order memory, bytes memory)
    {
        return _order(
            bytes.concat(
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                isFeeIn ? FeeFlatIn.build(100) : FeeFlatOut.build(100),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function _limitDeadline(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(
                Deadline.build(uint40(block.timestamp + 3600)),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function _limitSalt(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(
                Salt.build(12345678),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function _limitInvalidateBit(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(
                InvalidateBit.build(42),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function _limitInvalidateTokenIn(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                LimitSwap.build(address(tokenA), address(tokenB)),
                InvalidateTokenIn.build()
            ),
            isExactIn
        );
    }

    function _limitDutch(bool isAuctionIn, bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        bytes memory auction = isAuctionIn
            ? DutchAuctionBalanceIn.build(uint40(block.timestamp), 300, 0.5e18)
            : DutchAuctionBalanceOut.build(uint40(block.timestamp), 300, 0.5e18);
        return _order(
            bytes.concat(
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                auction,
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function _limitTWAP(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory, uint256) {
        uint256 startTime = block.timestamp;
        (ISwapVM.Order memory order, bytes memory takerData) = _order(
            bytes.concat(
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                TWAPSwap.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B, startTime, 3600, 1.2e18, 0.1e18),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
        return (order, takerData, startTime);
    }

    function _limitMinRate(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                AdjustMinRate.build(1e8, 1.5e8),
                LimitSwap.build(address(tokenA), address(tokenB))
            ),
            isExactIn
        );
    }

    function _limitFull(bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        return _order(
            bytes.concat(
                Deadline.build(uint40(block.timestamp + 3600)),
                Salt.build(99999),
                StaticBalances.build(LIMIT_BALANCE_A, LIMIT_BALANCE_B),
                FeeFlatIn.build(30),
                LimitSwap.build(address(tokenA), address(tokenB)),
                InvalidateTokenIn.build()
            ),
            isExactIn
        );
    }

    function _order(bytes memory program, bool isExactIn) private view returns (ISwapVM.Order memory, bytes memory) {
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
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
            program: program
        }));

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory thresholdData = isExactIn ? bytes("") : abi.encodePacked(bytes32(type(uint256).max));

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            threshold: thresholdData,
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

        return (order, abi.encodePacked(takerTraits));
    }
}
