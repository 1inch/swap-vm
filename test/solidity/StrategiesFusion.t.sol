// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { Strategies } from "../../contracts/strategies/Strategies.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { Time } from "../../contracts/libs/Time.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap, LimitSwapFullAmount } from "../../contracts/instructions/LimitSwap.sol";
import { FeeProtocol, FeeProtocolSurplus } from "../../contracts/instructions/FeeProtocol.sol";
import { InvalidateBit, InvalidateTokenOut } from "../../contracts/instructions/Invalidators.sol";
import { Jump } from "../../contracts/instructions/Jumps.sol";
import { PrivateOrder, WhitelistCoequal, WhitelistSequential } from "../../contracts/instructions/Whitelist.sol";
import { PiecewiseLinearSurcharge } from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { OraclePriceAdjuster } from "../../contracts/instructions/OraclePriceAdjuster.sol";
import { BaseFeeAdjuster } from "../../contracts/instructions/BaseFeeAdjuster.sol";
import { OnlyTakerTokenBalanceNonZero } from "../../contracts/instructions/TokenValidators.sol";
import { Deadline, Salt } from "../../contracts/instructions/Controls.sol";
import { PriceOracleMock } from "./mocks/PriceOracleMock.sol";

/**
 * @title StrategiesFusion
 * @notice Tests for the Fusion settlement shaped order builder
 */
contract StrategiesFusionTest is Test {
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;
    TokenMock public kyc;
    PriceOracleMock public oracle;

    uint256 public makerPK = 0x1234;
    address public maker = vm.addr(0x1234);
    address public resolver1 = makeAddr("resolver1");
    address public resolver2 = makeAddr("resolver2");
    address public alien = makeAddr("alien");
    address public stranger = makeAddr("stranger");
    address public integrator = makeAddr("integrator");
    address public protocol = makeAddr("protocol");

    uint40 constant START = 1_700_000_000;
    uint256 constant BALANCE_IN = 100e18;
    uint256 constant BALANCE_OUT = 200e18;
    uint256 constant ESTIMATED_IN = 120e18;
    // Token out priced at 0.5 token in by the oracle, so the market values `BALANCE_OUT` at `BALANCE_IN`
    int256 constant ORACLE_PRICE = 0.5e18;
    uint160 constant MARKET_VALUE = uint160(BALANCE_IN);
    uint24 constant MAX_STALENESS = 1 hours;

    FeeProtocol.ProviderConfig[] internal noProviders;

    function setUp() public {
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        kyc = new TokenMock("Access token", "KYC");
        oracle = new PriceOracleMock(ORACLE_PRICE, START - 1000);

        tokenB.mint(maker, 1e30);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        kyc.mint(alien, 1);
        vm.fee(0);
    }

    // Shape tests

    function test_StrategiesFusion_FullLayout() public view {
        Strategies.FusionOrder memory args = _fullArgs();
        bytes memory program = this.fusionOrder(_prefix(), args);

        bytes memory head = bytes.concat(
            Deadline.build(START + 1000),
            Salt.build(uint64(42)),
            StaticBalances.build(BALANCE_IN, BALANCE_OUT)
        );
        bytes memory whitelist = WhitelistSequential.build(START, 0, args.whitelistResolvers, args.whitelistDelays);
        bytes memory gate = OnlyTakerTokenBalanceNonZero.build(address(kyc));
        bytes memory publicFees = FeeProtocol.build(true, args.feeReceivers, noProviders);
        bytes memory whitelistedFees = FeeProtocol.build(true, _receivers(0.0025e7, 0.01e7, 0.1e7), noProviders);

        uint16 whitelistedPC = uint16(head.length + whitelist.length + gate.length + publicFees.length + Jump.sizeOf());
        uint16 commonPC = whitelistedPC + uint16(whitelistedFees.length);

        assertEq(program, bytes.concat(
            head,
            WhitelistSequential.build(START, whitelistedPC, args.whitelistResolvers, args.whitelistDelays),
            gate,
            publicFees,
            Jump.build(commonPC),
            whitelistedFees,
            FeeProtocolSurplus.build(true, ESTIMATED_IN),
            PiecewiseLinearSurcharge.build(true, START, args.auctionDurations, args.auctionScales),
            OraclePriceAdjuster.build(true, MARKET_VALUE, 18, 18, args.oracleFeeds),
            BaseFeeAdjuster.build(true, 0, 3000e18, 150_000),
            InvalidateTokenOut.build(),
            LimitSwap.build(true)
        ));
    }

    function test_StrategiesFusion_CoequalWhitelistLayout() public view {
        Strategies.FusionOrder memory args = _fullArgs();
        args.whitelistCoequal = true;
        args.whitelistStartTime = 0;
        args.whitelistDelays = new uint16[](0);

        bytes memory program = this.fusionOrder(new bytes[](0), args);

        bytes memory head = StaticBalances.build(BALANCE_IN, BALANCE_OUT);
        bytes memory whitelist = WhitelistCoequal.build(0, args.whitelistResolvers);
        bytes memory gate = OnlyTakerTokenBalanceNonZero.build(address(kyc));
        bytes memory publicFees = FeeProtocol.build(true, args.feeReceivers, noProviders);
        bytes memory whitelistedFees = FeeProtocol.build(true, _receivers(0.0025e7, 0.01e7, 0.1e7), noProviders);

        uint16 whitelistedPC = uint16(head.length + whitelist.length + gate.length + publicFees.length + Jump.sizeOf());
        uint16 commonPC = whitelistedPC + uint16(whitelistedFees.length);

        assertEq(program, bytes.concat(
            head,
            WhitelistCoequal.build(whitelistedPC, args.whitelistResolvers),
            gate,
            publicFees,
            Jump.build(commonPC),
            whitelistedFees,
            FeeProtocolSurplus.build(true, ESTIMATED_IN),
            PiecewiseLinearSurcharge.build(true, START, args.auctionDurations, args.auctionScales),
            OraclePriceAdjuster.build(true, MARKET_VALUE, 18, 18, args.oracleFeeds),
            BaseFeeAdjuster.build(true, 0, 3000e18, 150_000),
            InvalidateTokenOut.build(),
            LimitSwap.build(true)
        ));
    }

    function test_StrategiesFusion_WhitelistOnlyLayout() public view {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.whitelistStartTime = START;
        args.whitelistResolvers = dynamic([resolver1, resolver2]);
        args.whitelistDelays = dynamic([uint16(10), 10]);

        bytes memory head = StaticBalances.build(BALANCE_IN, BALANCE_OUT);
        bytes memory whitelist = WhitelistSequential.build(START, 0, args.whitelistResolvers, args.whitelistDelays);

        // Nothing on either branch: whitelisted resolvers jump over the public jump, which jumps over nothing
        uint16 whitelistedPC = uint16(head.length + whitelist.length + Jump.sizeOf());

        assertEq(this.fusionOrder(new bytes[](0), args), bytes.concat(
            head,
            WhitelistSequential.build(START, whitelistedPC, args.whitelistResolvers, args.whitelistDelays),
            Jump.build(whitelistedPC),
            InvalidateTokenOut.build(),
            LimitSwap.build(true)
        ));
    }

    function test_StrategiesFusion_MinimalLayout() public view {
        Strategies.FusionOrder memory args = _minimalArgs();

        assertEq(this.fusionOrder(new bytes[](0), args), bytes.concat(
            StaticBalances.build(BALANCE_IN, BALANCE_OUT),
            InvalidateTokenOut.build(),
            LimitSwap.build(true)
        ));
    }

    function test_StrategiesFusion_FillOrKillLayout() public view {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.allowPartialFills = false;
        args.allowMultipleFills = false;
        args.nonce = 7;
        _setAuction(args);

        assertEq(this.fusionOrder(new bytes[](0), args), bytes.concat(
            StaticBalances.build(BALANCE_IN, BALANCE_OUT),
            PiecewiseLinearSurcharge.build(true, START, args.auctionDurations, args.auctionScales),
            InvalidateBit.build(7),
            LimitSwapFullAmount.build(true)
        ));
    }

    function test_StrategiesFusion_SinglePartialFillLayout() public view {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.allowMultipleFills = false;
        args.nonce = 7;

        assertEq(this.fusionOrder(new bytes[](0), args), bytes.concat(
            StaticBalances.build(BALANCE_IN, BALANCE_OUT),
            InvalidateBit.build(7),
            LimitSwap.build(true)
        ));
    }

    // Validation tests

    function test_StrategiesFusion_RevertWhitelistDiscountWithoutWhitelist() public {
        Strategies.FusionOrder memory args = _fullArgs();
        args.whitelistResolvers = new address[](0);
        args.whitelistDelays = new uint16[](0);

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(_prefix(), args);
    }

    function test_StrategiesFusion_RevertWhitelistDiscountAboveFull() public {
        Strategies.FusionOrder memory args = _fullArgs();
        args.whitelistFeeDiscount = 1e7 + 1;

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(_prefix(), args);
    }

    function test_StrategiesFusion_RevertCoequalWhitelistWithSchedule() public {
        Strategies.FusionOrder memory args = _fullArgs();
        args.whitelistCoequal = true;

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(_prefix(), args);
    }

    function test_StrategiesFusion_RevertOracleMarketValueWithoutFeeds() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.oracleMarketValue = MARKET_VALUE;

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(new bytes[](0), args);
    }

    function test_StrategiesFusion_RevertGasBumpWithoutAuction() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setGasBump(args);

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(new bytes[](0), args);
    }

    function test_StrategiesFusion_RevertSurplusEstimationBelowBalanceIn() public {
        Strategies.FusionOrder memory args = _fullArgs();
        args.surplusEstimation = BALANCE_IN - 1;

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(_prefix(), args);
    }

    function test_StrategiesFusion_RevertSurplusEstimationBelowBalanceInReverse() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.direction = false;
        args.feeReceivers = _receivers(0, 0.02e7, 0.1e7);
        // Above balance A, below balance B, which is the input side now
        args.surplusEstimation = 150e18;

        vm.expectRevert(Strategies.OrderInconsistent.selector);
        this.fusionOrder(new bytes[](0), args);
    }

    function test_StrategiesFusion_RevertWhitelistTargetOverflow() public {
        // 5500 private-order prefixes of 12 bytes push the whitelist target past uint16
        bytes[] memory prefix = new bytes[](5500);
        for (uint256 i; i < prefix.length; i++) prefix[i] = PrivateOrder.build(resolver1);

        Strategies.FusionOrder memory args = _minimalArgs();
        args.whitelistCoequal = true;
        args.whitelistResolvers = dynamic([resolver1]);

        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        this.fusionOrder(prefix, args);
    }

    function test_StrategiesFusion_RevertWhitelistLengthMismatch() public {
        Strategies.FusionOrder memory args = _fullArgs();
        args.whitelistDelays = dynamic([uint16(10)]);

        vm.expectRevert(WhitelistSequential.WhitelistSequentialLengthMismatch.selector);
        this.fusionOrder(_prefix(), args);
    }

    // Execution tests

    function test_StrategiesFusion_WhitelistGateAndFees() public {
        ISwapVM.Order memory order = _order(this.fusionOrder(_prefix(), _fullArgs()));
        bytes memory exactInData = _takerData(order);

        // Nobody fills before the whitelist start
        vm.warp(START - 1);
        vm.prank(resolver1);
        vm.expectRevert(WhitelistSequential.WhitelistSequentialTimeViolation.selector);
        swapVM.quote(order, 150e18, exactInData);

        // First resolver is exclusive at start
        vm.warp(START);
        vm.prank(resolver2);
        vm.expectRevert(WhitelistSequential.WhitelistSequentialTimeViolation.selector);
        swapVM.quote(order, 150e18, exactInData);
        vm.prank(alien);
        vm.expectRevert(WhitelistSequential.WhitelistSequentialTimeViolation.selector);
        swapVM.quote(order, 150e18, exactInData);

        // Auction start: +50% surcharge, 150e18 in buys the whole 200e18 out before the halved 1.25% flat fee
        tokenA.mint(resolver1, 150e18);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 150e18, exactInData);
        vm.stopPrank();

        assertEq(amountIn, 150e18);
        assertEq(amountOut, 197.5e18, "148.125e18 net in at 150e18 per 200e18");
        assertEq(tokenB.balanceOf(resolver1), 197.5e18);
        // Flat 1.5e18 plus 10% of the 29.625e18 surplus over the 118.5e18 pro-rata estimate
        assertEq(tokenA.balanceOf(protocol), 4.4625e18, "Whitelisted protocol fee");
        assertEq(tokenA.balanceOf(integrator), 0.375e18, "Half the 0.5% integrator fee");
        assertEq(tokenA.balanceOf(maker), 145.1625e18, "Maker receives input minus fees");
        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), 197.5e18);

        // Second resolver unlocks after the first delay, public still locked
        vm.warp(START + 10);
        vm.prank(resolver2);
        (, uint256 resolver2Out,) = swapVM.quote(order, 1e18, exactInData);
        assertGt(resolver2Out, 0);
        vm.prank(alien);
        vm.expectRevert(WhitelistSequential.WhitelistSequentialTimeViolation.selector);
        swapVM.quote(order, 1e18, exactInData);

        // Public path: access token required, full fees charged
        vm.warp(START + 20);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OnlyTakerTokenBalanceNonZero.TakerTokenBalanceIsZero.selector, stranger, address(kyc)));
        swapVM.quote(order, 1e18, exactInData);

        vm.prank(alien);
        (, uint256 alienOut,) = swapVM.quote(order, 1e18, exactInData);
        vm.prank(resolver1);
        (, uint256 resolver1Out,) = swapVM.quote(order, 1e18, exactInData);
        assertGt(alienOut, 0);
        assertGt(resolver1Out, alienOut, "Whitelisted resolvers pay lower fees");
    }

    function test_StrategiesFusion_AuctionDecaysToBalanceIn() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setAuction(args);

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        vm.warp(START);
        (, uint256 startOut,) = swapVM.quote(order, 1e18, exactInData);
        vm.warp(START + 50);
        (, uint256 middleOut,) = swapVM.quote(order, 1e18, exactInData);
        vm.warp(START + 100);
        (, uint256 endOut,) = swapVM.quote(order, 1e18, exactInData);

        assertEq(startOut, 1e18 * BALANCE_OUT / (BALANCE_IN * 3 / 2), "+50% at start");
        assertGt(middleOut, startOut);
        assertGt(endOut, middleOut);
        assertEq(endOut, 1e18 * BALANCE_OUT / BALANCE_IN, "Order rate at the end");
    }

    function test_StrategiesFusion_OracleShiftsPrice() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setAuction(args);
        _setOracle(args);

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        // Auction start: +50% surcharge, 150e18 in for 200e18 out while the oracle sits at the market value
        vm.warp(START);
        (, uint256 amountOut,) = swapVM.quote(order, 15e18, exactInData);
        assertEq(amountOut, 20e18, "Oracle at market changes nothing");

        // Market up 20%: the maker asks 20e18 more on top of the auction surcharge
        oracle.setRoundData(ORACLE_PRICE * 6 / 5, START);
        (, amountOut,) = swapVM.quote(order, 17e18, exactInData);
        assertEq(amountOut, 20e18, "Rise adds to the receive");

        // Market down 20%: the drop consumes the surcharge, 130e18 in for 200e18 out
        oracle.setRoundData(ORACLE_PRICE * 4 / 5, START);
        (, amountOut,) = swapVM.quote(order, 13e18, exactInData);
        assertEq(amountOut, 20e18, "Fall consumes the surcharge");

        // Auction over: no surcharge left to consume, the limit price holds
        vm.warp(START + 100);
        (, amountOut,) = swapVM.quote(order, 10e18, exactInData);
        assertEq(amountOut, 20e18, "Limit price holds");

        // Stale feed reverts
        vm.warp(START + MAX_STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterOraclePriceStale.selector, START + MAX_STALENESS + 1, START, MAX_STALENESS
        ));
        swapVM.quote(order, 10e18, exactInData);
    }

    function test_StrategiesFusion_CoequalWhitelistExecution() public {
        Strategies.FusionOrder memory args = _fullArgs();
        args.whitelistCoequal = true;
        args.whitelistStartTime = 0;
        args.whitelistDelays = new uint16[](0);

        ISwapVM.Order memory order = _order(this.fusionOrder(_prefix(), args));
        bytes memory exactInData = _takerData(order);

        // No exclusivity: every resolver and the public fill at once, the public still needs the access token
        vm.warp(START);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OnlyTakerTokenBalanceNonZero.TakerTokenBalanceIsZero.selector, stranger, address(kyc)));
        swapVM.quote(order, 1e18, exactInData);

        vm.prank(alien);
        (, uint256 alienOut,) = swapVM.quote(order, 1e18, exactInData);
        vm.prank(resolver2);
        (, uint256 resolver2Out,) = swapVM.quote(order, 1e18, exactInData);
        assertGt(alienOut, 0);
        assertGt(resolver2Out, alienOut, "Whitelisted resolvers pay lower fees");
    }

    function test_StrategiesFusion_FillOrKillExecution() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.allowPartialFills = false;
        args.allowMultipleFills = false;
        args.nonce = 7;

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        tokenA.mint(resolver1, 1e30);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(LimitSwapFullAmount.LimitSwapAmountShouldCoverBalance.selector, 50e18, BALANCE_IN));
        swapVM.swap(order, 50e18, exactInData);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, BALANCE_IN, exactInData);
        assertEq(amountIn, BALANCE_IN);
        assertEq(amountOut, BALANCE_OUT);

        vm.expectRevert(abi.encodeWithSelector(InvalidateBit.InvalidateBitAlreadySet.selector, maker, 7, 1 << 7));
        swapVM.swap(order, BALANCE_IN, exactInData);
        vm.stopPrank();
    }

    function test_StrategiesFusion_GasBumpDiscountsWithinSurcharge() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setAuction(args);
        _setGasBump(args);

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        // 10 gwei * 150k gas at 3000 token in per ETH = 4.5e18 off the 150e18 auction start
        vm.warp(START);
        vm.fee(10 gwei);
        (, uint256 amountOut,) = swapVM.quote(order, 14.55e18, exactInData);
        assertEq(amountOut, 20e18, "Gas cost taken off the surcharge");

        // 450e18 worth of gas is capped at the 50e18 surcharge, the limit price holds
        vm.fee(1000 gwei);
        (, amountOut,) = swapVM.quote(order, 10e18, exactInData);
        assertEq(amountOut, 20e18, "Discount capped at the surcharge");

        // Auction over: nothing left to discount
        vm.warp(START + 100);
        vm.fee(10 gwei);
        (, amountOut,) = swapVM.quote(order, 10e18, exactInData);
        assertEq(amountOut, 20e18, "No discount below the limit price");
    }

    function test_StrategiesFusion_MultipleFillsShareTheBalances() public {
        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), _minimalArgs()));
        bytes memory exactInData = _takerData(order);

        tokenA.mint(resolver1, 1e30);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 75e18, exactInData);
        assertEq(amountIn, 75e18);
        assertEq(amountOut, 150e18);

        // Only 50e18 out remain, the fill is clamped to what buys them
        (amountIn, amountOut,) = swapVM.swap(order, 50e18, exactInData);
        assertEq(amountIn, 25e18, "Clamped to the remaining balance in");
        assertEq(amountOut, 50e18, "Remaining balance out");

        assertEq(tokenA.balanceOf(maker), BALANCE_IN);
        assertEq(tokenB.balanceOf(resolver1), BALANCE_OUT);
        assertEq(swapVM.tokenOutInvalidators(maker, swapVM.hash(order), address(tokenB)), BALANCE_OUT);

        // Nothing left: the fill degenerates to zero and is rejected
        vm.expectRevert(MakerTraitsLib.MakerTraitsZeroAmountInNotAllowed.selector);
        swapVM.swap(order, 1e18, exactInData);
        vm.stopPrank();
    }

    function test_StrategiesFusion_SurplusFeeOnlyAboveEstimation() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setAuction(args);
        args.feeReceivers = _receivers(0, 0.02e7, 0.1e7);
        args.surplusEstimation = ESTIMATED_IN;

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        // Auction over: 100e18 in nets 98e18 after the flat fee, below the 117.6e18 pro-rata estimate
        vm.warp(START + 100);
        tokenA.mint(resolver1, 100e18);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactInData);
        vm.stopPrank();

        assertEq(amountIn, 100e18);
        assertEq(amountOut, 196e18);
        assertEq(tokenA.balanceOf(protocol), 2e18, "Flat fee only");
        assertEq(tokenA.balanceOf(maker), 98e18);
    }

    function test_StrategiesFusion_OneDirectionOnly() public {
        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), _minimalArgs()));
        bytes memory bToAData = _takerData(order, false);

        vm.expectRevert(LimitSwap.LimitSwapDirectionMismatch.selector);
        swapVM.quote(order, 10e18, bToAData);
    }

    function test_StrategiesFusion_ReverseDirectionSellsTokenA() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.direction = false;
        args.balanceA = BALANCE_OUT;
        args.balanceB = BALANCE_IN;

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory bToAData = _takerData(order, false);
        bytes memory aToBData = _takerData(order, true);

        (, uint256 amountOut,) = swapVM.quote(order, 10e18, bToAData);
        assertEq(amountOut, 20e18, "10 token B buys 20 token A");

        vm.expectRevert(LimitSwap.LimitSwapDirectionMismatch.selector);
        swapVM.quote(order, 10e18, aToBData);
    }

    function test_StrategiesFusion_AccessTokenGatesEveryoneWithoutWhitelist() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.accessToken = address(kyc);

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        vm.prank(resolver1);
        vm.expectRevert(abi.encodeWithSelector(OnlyTakerTokenBalanceNonZero.TakerTokenBalanceIsZero.selector, resolver1, address(kyc)));
        swapVM.quote(order, 10e18, exactInData);

        vm.prank(alien);
        (, uint256 amountOut,) = swapVM.quote(order, 10e18, exactInData);
        assertEq(amountOut, 20e18, "Holder fills at the order rate");
    }

    function test_StrategiesFusion_SinglePartialFillBurnsTheNonce() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.allowMultipleFills = false;
        args.nonce = 3;

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        tokenA.mint(resolver1, 1e30);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);

        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 50e18, exactInData);
        assertEq(amountIn, 50e18);
        assertEq(amountOut, 100e18, "Half the order at the order rate");

        vm.expectRevert(abi.encodeWithSelector(InvalidateBit.InvalidateBitAlreadySet.selector, maker, 3, 1 << 3));
        swapVM.swap(order, 50e18, exactInData);
        vm.stopPrank();
    }

    function test_StrategiesFusion_AuctionRelativeToAnnouncement() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setAuction(args);
        args.auctionStartTime = Time.RELATIVE_TIME_FLAG | 100;

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        vm.warp(START);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        swapVM.registerOrder(order, abi.encodePacked(r, s, v));

        // Announced at START, the auction runs START + 100 .. START + 200: half decayed at START + 150
        vm.warp(START + 150);
        (, uint256 amountOut,) = swapVM.quote(order, 12.5e18, exactInData);
        assertEq(amountOut, 20e18, "+25% halfway through the auction");

        vm.warp(START + 200);
        (, amountOut,) = swapVM.quote(order, 10e18, exactInData);
        assertEq(amountOut, 20e18, "Limit price at the end");
    }

    function test_StrategiesFusion_PrefixExpiresAndPinsTheOrder() public {
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = Deadline.build(START + 1000);
        prefix[1] = PrivateOrder.build(resolver1);

        ISwapVM.Order memory order = _order(this.fusionOrder(prefix, _minimalArgs()));
        bytes memory exactInData = _takerData(order);

        vm.warp(START);
        vm.prank(resolver1);
        (, uint256 amountOut,) = swapVM.quote(order, 10e18, exactInData);
        assertEq(amountOut, 20e18);

        vm.prank(resolver2);
        vm.expectRevert(PrivateOrder.PrivateOrderInvalidTaker.selector);
        swapVM.quote(order, 10e18, exactInData);

        vm.warp(START + 1001);
        vm.prank(resolver1);
        vm.expectRevert(abi.encodeWithSelector(Deadline.DeadlineReached.selector, START + 1000));
        swapVM.quote(order, 10e18, exactInData);
    }

    function test_StrategiesFusion_WhitelistedResolversPayNothing() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.whitelistCoequal = true;
        args.whitelistResolvers = dynamic([resolver1]);
        args.feeReceivers = _receivers(0, 0.02e7, 0);
        args.whitelistFeeDiscount = 1e7;

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        tokenA.mint(resolver1, 50e18);
        tokenA.mint(alien, 50e18);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);
        (, uint256 resolverOut,) = swapVM.swap(order, 50e18, exactInData);
        vm.stopPrank();
        vm.startPrank(alien);
        tokenA.approve(address(swapVM), type(uint256).max);
        (, uint256 alienOut,) = swapVM.swap(order, 50e18, exactInData);
        vm.stopPrank();

        assertEq(resolverOut, 100e18, "Whole 50e18 at the order rate");
        assertEq(alienOut, 98e18, "49e18 net after 2%");
        assertEq(tokenA.balanceOf(protocol), 1e18, "Fee from the public fill only");
        assertEq(tokenA.balanceOf(maker), 99e18);
    }

    function test_StrategiesFusion_ExactOutFillPaysFeeOnTop() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        args.feeReceivers = _receivers(0, 0.2e7, 0);

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactOutData = _takerData(order, true, false);

        tokenA.mint(resolver1, 100e18);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(order, 100e18, exactOutData);
        vm.stopPrank();

        assertEq(amountOut, 100e18, "Requested output");
        assertEq(amountIn, 62.5e18, "50e18 for the maker plus 20% fee on the gross");
        assertEq(tokenA.balanceOf(maker), 50e18);
        assertEq(tokenA.balanceOf(protocol), 12.5e18);
    }

    function test_StrategiesFusion_OracleShiftSharedAcrossFills() public {
        Strategies.FusionOrder memory args = _minimalArgs();
        _setOracle(args);
        oracle.setRoundData(ORACLE_PRICE * 6 / 5, START);

        ISwapVM.Order memory order = _order(this.fusionOrder(new bytes[](0), args));
        bytes memory exactInData = _takerData(order);

        vm.warp(START);
        tokenA.mint(resolver1, 120e18);
        vm.startPrank(resolver1);
        tokenA.approve(address(swapVM), type(uint256).max);
        (, uint256 firstOut,) = swapVM.swap(order, 60e18, exactInData);
        (, uint256 secondOut,) = swapVM.swap(order, 60e18, exactInData);
        vm.stopPrank();

        assertEq(firstOut, 100e18, "Market up 20%: 120e18 buys the whole order");
        assertEq(secondOut, 100e18, "Same rate for the remaining half");
        assertEq(tokenA.balanceOf(maker), 120e18);
    }

    // Fixtures

    function _prefix() internal pure returns (bytes[] memory prefix) {
        prefix = new bytes[](2);
        prefix[0] = Deadline.build(START + 1000);
        prefix[1] = Salt.build(uint64(42));
    }

    function _setAuction(Strategies.FusionOrder memory args) internal pure {
        args.auctionStartTime = START;
        args.auctionDurations = dynamic([uint16(100)]);
        args.auctionScales = dynamic([uint24(1 << 23), 0]);
    }

    function _setGasBump(Strategies.FusionOrder memory args) internal pure {
        args.baseGasPrice = 0;
        args.ethPrice = 3000e18;
        args.gasAmount = 150_000;
    }

    function _setOracle(Strategies.FusionOrder memory args) internal view {
        args.oracleMarketValue = MARKET_VALUE;
        args.tokenInDecimals = 18;
        args.tokenOutDecimals = 18;
        args.oracleFeeds = new OraclePriceAdjuster.Feed[](1);
        args.oracleFeeds[0] = OraclePriceAdjuster.Feed({
            oracleDecimals: 18,
            isDenominator: false,
            maxStaleness: MAX_STALENESS,
            oracle: address(oracle)
        });
    }

    function _receivers(
        uint24 integratorBps,
        uint24 protocolBps,
        uint24 surplusBps
    ) internal view returns (FeeProtocol.ReceiverConfig[] memory receivers) {
        receivers = new FeeProtocol.ReceiverConfig[](integratorBps > 0 ? 2 : 1);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: protocol, feeBps: protocolBps, surplusBps: surplusBps });
        if (integratorBps > 0) {
            receivers[1] = FeeProtocol.ReceiverConfig({ receiver: integrator, feeBps: integratorBps, surplusBps: 0 });
        }
    }

    function _minimalArgs() internal pure returns (Strategies.FusionOrder memory) {
        return Strategies.FusionOrder({
            balanceA: BALANCE_IN,
            balanceB: BALANCE_OUT,
            direction: true,
            allowPartialFills: true,
            allowMultipleFills: true,
            nonce: 0,
            auctionStartTime: 0,
            auctionDurations: new uint16[](0),
            auctionScales: new uint24[](0),
            oracleMarketValue: 0,
            tokenInDecimals: 0,
            tokenOutDecimals: 0,
            oracleFeeds: new OraclePriceAdjuster.Feed[](0),
            baseGasPrice: 0,
            ethPrice: 0,
            gasAmount: 0,
            whitelistCoequal: false,
            whitelistStartTime: 0,
            whitelistResolvers: new address[](0),
            whitelistDelays: new uint16[](0),
            accessToken: address(0),
            feeReceivers: new FeeProtocol.ReceiverConfig[](0),
            whitelistFeeDiscount: 0,
            surplusEstimation: 0
        });
    }

    /// @dev Two resolvers unlocked 10 seconds apart, public after 20 seconds with access token
    ///   Public takers pay 0.5% to the integrator and 2% + 10% surplus to the protocol,
    ///   whitelisted resolvers pay half the flat fees and the same surplus
    ///   The oracle sits at the market value the order was priced at, so it shifts nothing
    function _fullArgs() internal view returns (Strategies.FusionOrder memory args) {
        args = _minimalArgs();
        _setAuction(args);
        _setOracle(args);
        _setGasBump(args);
        args.whitelistStartTime = START;
        args.whitelistResolvers = dynamic([resolver1, resolver2]);
        args.whitelistDelays = dynamic([uint16(10), 10]);
        args.accessToken = address(kyc);
        args.feeReceivers = _receivers(0.005e7, 0.02e7, 0.1e7);
        args.whitelistFeeDiscount = 0.5e7;
        args.surplusEstimation = ESTIMATED_IN;
    }

    function _order(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            usePermit2: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            program: program
        }));
    }

    function _takerData(ISwapVM.Order memory order) internal view returns (bytes memory) {
        return _takerData(order, true);
    }

    function _takerData(ISwapVM.Order memory order, bool isAToB) internal view returns (bytes memory) {
        return _takerData(order, isAToB, true);
    }

    function _takerData(ISwapVM.Order memory order, bool isAToB, bool isExactIn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: true,
            usePermit2: false,
            threshold: "",
            to: address(0),
            hasPreTransferInCallback: false,
            signature: abi.encodePacked(r, s, v)
        }));
    }

    // External routing memory test data into the calldata-only builder

    function fusionOrder(bytes[] calldata prefix, Strategies.FusionOrder calldata args) external pure returns (bytes memory) {
        return Strategies.buildFusionOrder(prefix, args);
    }
}
