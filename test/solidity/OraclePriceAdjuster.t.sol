// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import {
    PiecewiseLinearSurchargeBalanceIn,
    PiecewiseLinearSurchargeBalanceOut
} from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { BaseFeeAdjusterBalanceIn } from "../../contracts/instructions/BaseFeeAdjuster.sol";
import {
    OraclePriceAdjuster,
    OraclePriceAdjusterBalanceIn,
    OraclePriceAdjusterBalanceOut
} from "../../contracts/instructions/OraclePriceAdjuster.sol";

contract PriceOracleMock {
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(int256 answer_, uint256 updatedAt_) {
        setRoundData(answer_, updatedAt_);
    }

    function setRoundData(int256 answer_, uint256 updatedAt_) public {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

contract OraclePriceAdjusterTest is Test {
    using Math for uint256;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;

    uint256 private constant MAKER_PK = 0x1234;
    uint256 private constant TEST_TIMESTAMP = 1_000_000;
    uint24 private constant MAX_STALENESS = 300;

    address private maker;

    function setUp() public {
        vm.warp(TEST_TIMESTAMP);

        maker = vm.addr(MAKER_PK);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.startPrank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.stopPrank();
    }

    function test_OraclePriceAdjusterBalanceIn_ShiftsUSDCWETHPrice() public {
        PriceOracleMock oracle = new PriceOracleMock(2550e8, block.timestamp);
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(oracle, 8, false)
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));
        (, uint256 amountOut,) = swapVM.quote(order, 2650e6, _buildTakerData(order, true));

        assertEq(amountIn, 2650e6);
        assertEq(amountOut, 1e18);
    }

    function test_OraclePriceAdjuster_FeedDirectionRounding() public {
        PriceOracleMock directOracle = new PriceOracleMock(2550e8, block.timestamp);
        PriceOracleMock inverseOracle = new PriceOracleMock(392156862745098, block.timestamp);
        ISwapVM.Order memory directOrder = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(directOracle, 8, false)
        ));
        ISwapVM.Order memory inverseOrder = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(inverseOracle, 18, true)
        ));

        (uint256 directAmountIn,,) = swapVM.quote(
            directOrder,
            1e18,
            _buildTakerData(directOrder, false)
        );
        (uint256 inverseAmountIn,,) = swapVM.quote(
            inverseOrder,
            1e18,
            _buildTakerData(inverseOrder, false)
        );

        assertEq(directAmountIn, 2650e6);
        assertEq(inverseAmountIn, directAmountIn + 1);
    }

    function test_OraclePriceAdjusterBalanceOut_ShiftsUSDCWETHPrice() public {
        PriceOracleMock oracle = new PriceOracleMock(2550e8, block.timestamp);
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            false,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(oracle, 8, false)
        ));
        uint256 marketValue = uint256(2600e6) * 1e18 / 2500e6;
        uint256 oracleValue = uint256(2600e6) * 1e18 / 2550e6;
        uint256 expectedBalanceOut = 1e18 - (marketValue - oracleValue);

        (, uint256 amountOut,) = swapVM.quote(order, 2600e6, _buildTakerData(order, true));
        (uint256 amountIn,,) = swapVM.quote(order, expectedBalanceOut, _buildTakerData(order, false));

        assertEq(amountOut, expectedBalanceOut);
        assertEq(amountIn, 2600e6);
    }

    function test_OraclePriceAdjuster_DoesNotAdjustBelowMarketWithoutSurcharge() public {
        PriceOracleMock oracle = new PriceOracleMock(2400e8, block.timestamp);
        bytes memory feed = _feed(oracle, 8, false);

        ISwapVM.Order memory balanceInOrder = _buildOrder(
            _buildProgram(true, 2600e6, 1e18, 2500e18, 6, 18, feed)
        );
        ISwapVM.Order memory balanceOutOrder = _buildOrder(
            _buildProgram(false, 2600e6, 1e18, 2500e18, 6, 18, feed)
        );

        (uint256 amountIn,,) = swapVM.quote(
            balanceInOrder,
            1e18,
            _buildTakerData(balanceInOrder, false)
        );
        (, uint256 amountOut,) = swapVM.quote(
            balanceOutOrder,
            2600e6,
            _buildTakerData(balanceOutOrder, true)
        );

        assertEq(amountIn, 2600e6);
        assertEq(amountOut, 1e18);
    }

    function test_OraclePriceAdjuster_ConsumesBalanceInSurchargeWhenPriceFalls() public {
        PriceOracleMock oracle = new PriceOracleMock(2400e8, block.timestamp);
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = uint24(1 << 23);
        scales[1] = uint24(1 << 23);

        ISwapVM.Order memory order = _buildOrder(bytes.concat(
            StaticBalances.build(2000e6, 1e18),
            PiecewiseLinearSurchargeBalanceIn.build(
                uint40(block.timestamp),
                durations,
                scales
            ),
            _buildBalanceIn(
                2500e6,
                6,
                18,
                _feed(oracle, 8, false)
            ),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));
        assertEq(amountIn, 2900e6);

        oracle.setRoundData(1000e8, block.timestamp);
        (amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));
        assertEq(amountIn, 2000e6);
    }

    function test_OraclePriceAdjuster_ConsumesBalanceOutSurchargeWhenPriceFalls() public {
        PriceOracleMock oracle = new PriceOracleMock(2400e8, block.timestamp);
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = uint24(1 << 23);
        scales[1] = uint24(1 << 23);

        ISwapVM.Order memory order = _buildOrder(bytes.concat(
            StaticBalances.build(2500e6, 1.5e18),
            PiecewiseLinearSurchargeBalanceOut.build(
                uint40(block.timestamp),
                durations,
                scales
            ),
            _buildBalanceOut(
                1e18,
                6,
                18,
                _feed(oracle, 8, false)
            ),
            LimitSwap.build(address(tokenA), address(tokenB))
        ));

        (, uint256 amountOut,) = swapVM.quote(order, 2500e6, _buildTakerData(order, true));
        assertEq(amountOut, 1.041666666666666666e18);

        oracle.setRoundData(1000e8, block.timestamp);
        (, amountOut,) = swapVM.quote(order, 2500e6, _buildTakerData(order, true));
        assertEq(amountOut, 1.5e18);
    }

    function test_OraclePriceAdjuster_MultiFeedAndReverseTokenDecimals() public {
        PriceOracleMock usdcUsd = new PriceOracleMock(1e8, block.timestamp);
        PriceOracleMock wethUsd = new PriceOracleMock(2000e8, block.timestamp);
        bytes memory feeds = bytes.concat(
            _feed(usdcUsd, 8, false),
            _feed(wethUsd, 8, true)
        );
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            0.4e18,
            1000e6,
            0.0004e18,
            18,
            6,
            feeds
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1000e6, _buildTakerData(order, false));

        assertEq(amountIn, 0.5e18);
    }

    function test_OraclePriceAdjuster_MultipliesTwoFeedsWithDifferentDecimals() public {
        PriceOracleMock tokenAMiddle = new PriceOracleMock(2e6, block.timestamp);
        PriceOracleMock middleTokenB = new PriceOracleMock(4e8, block.timestamp);
        bytes memory feeds = bytes.concat(
            _feed(tokenAMiddle, 6, false),
            _feed(middleTokenB, 8, false)
        );
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            7e18,
            1e18,
            7e18,
            18,
            18,
            feeds
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));

        assertEq(amountIn, 8e18);
    }

    function test_OraclePriceAdjuster_DividesByTwoFeeds() public {
        PriceOracleMock middleTokenA = new PriceOracleMock(2e8, block.timestamp);
        PriceOracleMock tokenBMiddle = new PriceOracleMock(4e8, block.timestamp);
        bytes memory feeds = bytes.concat(
            _feed(middleTokenA, 8, true),
            _feed(tokenBMiddle, 8, true)
        );
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            0.1e18,
            1e18,
            0.1e18,
            18,
            18,
            feeds
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));

        assertEq(amountIn, 0.125e18);
    }

    function test_OraclePriceAdjusterBalanceIn_TwoFeedsAllDirections() public {
        _assertBalanceInTwoFeeds(2e18, false, 4e18, false);
        _assertBalanceInTwoFeeds(16e18, false, 2e18, true);
        _assertBalanceInTwoFeeds(0.5e18, true, 4e18, false);
        _assertBalanceInTwoFeeds(0.25e18, true, 0.5e18, true);
    }

    function test_OraclePriceAdjusterBalanceOut_TwoFeedsAllDirections() public {
        _assertBalanceOutTwoFeeds(2e18, false, 4e18, false);
        _assertBalanceOutTwoFeeds(16e18, false, 2e18, true);
        _assertBalanceOutTwoFeeds(0.5e18, true, 4e18, false);
        _assertBalanceOutTwoFeeds(0.25e18, true, 0.5e18, true);
    }

    function test_OraclePriceAdjuster_BalanceInAndOutBuildersMatch() public {
        PriceOracleMock oracleA = new PriceOracleMock(2e18, block.timestamp);
        PriceOracleMock oracleB = new PriceOracleMock(4e18, block.timestamp);

        bytes memory balanceInSingle = OraclePriceAdjusterBalanceIn.build(
            1e18, 18, 18, 18, false, MAX_STALENESS, address(oracleA)
        );
        bytes memory balanceOutSingle = OraclePriceAdjusterBalanceOut.build(
            1e18, 18, 18, 18, false, MAX_STALENESS, address(oracleA)
        );
        _assertSameEncoding(balanceInSingle, balanceOutSingle);

        bytes memory balanceInDouble = OraclePriceAdjusterBalanceIn.build(
            1e18,
            18,
            18,
            18,
            false,
            MAX_STALENESS,
            address(oracleA),
            18,
            true,
            MAX_STALENESS,
            address(oracleB)
        );
        bytes memory balanceOutDouble = OraclePriceAdjusterBalanceOut.build(
            1e18,
            18,
            18,
            18,
            false,
            MAX_STALENESS,
            address(oracleA),
            18,
            true,
            MAX_STALENESS,
            address(oracleB)
        );
        _assertSameEncoding(balanceInDouble, balanceOutDouble);
    }

    function test_OraclePriceAdjuster_RoundsScaledDeltaForMaker() public {
        PriceOracleMock oracle = new PriceOracleMock(2500e18 + 1, block.timestamp);
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(oracle, 18, false)
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));

        assertEq(amountIn, 2600e6 + 1);
    }

    function test_OraclePriceAdjuster_RunsAfterAuctionSurcharge() public {
        PriceOracleMock oracle = new PriceOracleMock(2550e8, block.timestamp);
        uint16[] memory durations = new uint16[](1);
        uint24[] memory scales = new uint24[](2);
        durations[0] = 1;
        scales[0] = uint24(1 << 23);
        scales[1] = uint24(1 << 23);

        bytes memory program = bytes.concat(
            StaticBalances.build(1950e6, 1e18),
            PiecewiseLinearSurchargeBalanceIn.build(
                uint40(block.timestamp),
                durations,
                scales
            ),
            _buildBalanceIn(
                2500e6,
                6,
                18,
                _feed(oracle, 8, false)
            ),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        ISwapVM.Order memory order = _buildOrder(program);

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));

        assertEq(amountIn, 2975e6);
    }

    function test_OraclePriceAdjuster_SurchargeCanBeConsumed() public {
        PriceOracleMock oracle = new PriceOracleMock(2550e8, block.timestamp);
        vm.fee(1 gwei);

        bytes memory program = bytes.concat(
            StaticBalances.build(2600e6, 1e18),
            _buildBalanceIn(
                2500e6,
                6,
                18,
                _feed(oracle, 8, false)
            ),
            BaseFeeAdjusterBalanceIn.build(0, 50e15, 1),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        ISwapVM.Order memory order = _buildOrder(program);

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));

        assertEq(amountIn, 2600e6);
    }

    function test_OraclePriceAdjuster_RevertsOnStaleFeed() public {
        uint256 updatedAt = block.timestamp - MAX_STALENESS - 1;
        PriceOracleMock oracle = new PriceOracleMock(2550e8, updatedAt);
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(oracle, 8, false)
        ));
        bytes memory takerData = _buildTakerData(order, false);

        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterOraclePriceStale.selector,
            block.timestamp,
            updatedAt,
            MAX_STALENESS
        ));
        swapVM.quote(order, 1e18, takerData);
    }

    function test_OraclePriceAdjuster_RevertsUsingSecondFeedStaleness() public {
        uint24 firstMaxStaleness = 500;
        uint24 secondMaxStaleness = 300;
        uint256 updatedAt = block.timestamp - secondMaxStaleness - 1;
        PriceOracleMock firstOracle = new PriceOracleMock(1e8, updatedAt);
        PriceOracleMock secondOracle = new PriceOracleMock(2550e8, updatedAt);
        bytes memory feeds = bytes.concat(
            _feed(firstOracle, 8, false, firstMaxStaleness),
            _feed(secondOracle, 8, false, secondMaxStaleness)
        );
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            feeds
        ));
        bytes memory takerData = _buildTakerData(order, false);

        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterOraclePriceStale.selector,
            block.timestamp,
            updatedAt,
            secondMaxStaleness
        ));
        swapVM.quote(order, 1e18, takerData);
    }

    function test_OraclePriceAdjuster_RevertsOnInvalidOraclePrice() public {
        PriceOracleMock oracle = new PriceOracleMock(-1, block.timestamp);
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            2600e6,
            1e18,
            2500e18,
            6,
            18,
            _feed(oracle, 8, false)
        ));
        bytes memory takerData = _buildTakerData(order, false);

        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterInvalidOraclePrice.selector,
            int256(-1)
        ));
        swapVM.quote(order, 1e18, takerData);
    }

    function test_OraclePriceAdjuster_BuildValidation() public {
        PriceOracleMock oracle = new PriceOracleMock(2550e8, block.timestamp);
        bytes memory validFeed = _feed(oracle, 8, false);

        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterInvalidMarketValue.selector,
            uint160(0)
        ));
        this.buildBalanceIn(0, 6, 18, validFeed);

        bytes memory zeroDecimalsFeed = _feed(oracle, 0, false);
        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterInvalidDecimalsExponent.selector,
            uint16(255)
        ));
        this.buildBalanceIn(2500e6, 255, 0, zeroDecimalsFeed);

        assertEq(
            this.buildBalanceIn(
                2500e6,
                19,
                18,
                _feed(oracle, 19, false)
            ).length,
            46
        );
        assertEq(
            this.buildBalanceIn(
                2500e6,
                6,
                18,
                _feed(oracle, 8, false, (1 << 23) - 1)
            ).length,
            46
        );

        bytes memory invalidStalenessFeed = _feed(oracle, 8, false, type(uint24).max);
        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness.selector,
            type(uint24).max
        ));
        this.buildBalanceIn(2500e6, 6, 18, invalidStalenessFeed);

        vm.expectRevert(abi.encodeWithSelector(
            OraclePriceAdjuster.OraclePriceAdjusterInvalidMaxStaleness.selector,
            type(uint24).max
        ));
        this.buildBalanceIn(
            2500e6,
            6,
            18,
            bytes.concat(validFeed, invalidStalenessFeed)
        );
    }

    function _assertBalanceInTwoFeeds(
        int256 answerA,
        bool isDenominatorA,
        int256 answerB,
        bool isDenominatorB
    ) private {
        PriceOracleMock oracleA = new PriceOracleMock(answerA, block.timestamp);
        PriceOracleMock oracleB = new PriceOracleMock(answerB, block.timestamp);
        bytes memory feeds = bytes.concat(
            _feed(oracleA, 18, isDenominatorA),
            _feed(oracleB, 18, isDenominatorB)
        );
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            true,
            7e18,
            1e18,
            7e18,
            18,
            18,
            feeds
        ));

        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));
        (, uint256 amountOut,) = swapVM.quote(order, 8e18, _buildTakerData(order, true));

        assertEq(amountIn, 8e18);
        assertEq(amountOut, 1e18);
    }

    function _assertBalanceOutTwoFeeds(
        int256 answerA,
        bool isDenominatorA,
        int256 answerB,
        bool isDenominatorB
    ) private {
        PriceOracleMock oracleA = new PriceOracleMock(answerA, block.timestamp);
        PriceOracleMock oracleB = new PriceOracleMock(answerB, block.timestamp);
        bytes memory feeds = bytes.concat(
            _feed(oracleA, 18, isDenominatorA),
            _feed(oracleB, 18, isDenominatorB)
        );
        uint256 balanceOut = uint256(8e18).mulDiv(1e18, 7e18);
        ISwapVM.Order memory order = _buildOrder(_buildProgram(
            false,
            8e18,
            balanceOut,
            7e18,
            18,
            18,
            feeds
        ));

        (, uint256 amountOut,) = swapVM.quote(order, 8e18, _buildTakerData(order, true));
        (uint256 amountIn,,) = swapVM.quote(order, 1e18, _buildTakerData(order, false));

        assertEq(amountOut, 1e18);
        assertEq(amountIn, 8e18);
    }

    function _assertSameEncoding(bytes memory balanceIn, bytes memory balanceOut) private pure {
        assertEq(balanceIn.length, balanceOut.length);
        for (uint256 i = 1; i < balanceIn.length; i++) {
            assertEq(uint8(balanceIn[i]), uint8(balanceOut[i]));
        }
    }

    function _buildBalanceIn(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory feeds
    ) private pure returns (bytes memory) {
        (
            uint8 oracleDecimalsA,
            bool isDenominatorA,
            uint24 maxStalenessA,
            address oracleA
        ) = _decodeFeed(feeds, 0);
        if (feeds.length == 24) {
            return OraclePriceAdjusterBalanceIn.build(
                marketValue,
                tokenInDecimals,
                tokenOutDecimals,
                oracleDecimalsA,
                isDenominatorA,
                maxStalenessA,
                oracleA
            );
        }

        (
            uint8 oracleDecimalsB,
            bool isDenominatorB,
            uint24 maxStalenessB,
            address oracleB
        ) = _decodeFeed(feeds, 24);
        return OraclePriceAdjusterBalanceIn.build(
            marketValue,
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimalsA,
            isDenominatorA,
            maxStalenessA,
            oracleA,
            oracleDecimalsB,
            isDenominatorB,
            maxStalenessB,
            oracleB
        );
    }

    function _buildBalanceOut(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory feeds
    ) private pure returns (bytes memory) {
        (
            uint8 oracleDecimalsA,
            bool isDenominatorA,
            uint24 maxStalenessA,
            address oracleA
        ) = _decodeFeed(feeds, 0);
        if (feeds.length == 24) {
            return OraclePriceAdjusterBalanceOut.build(
                marketValue,
                tokenInDecimals,
                tokenOutDecimals,
                oracleDecimalsA,
                isDenominatorA,
                maxStalenessA,
                oracleA
            );
        }

        (
            uint8 oracleDecimalsB,
            bool isDenominatorB,
            uint24 maxStalenessB,
            address oracleB
        ) = _decodeFeed(feeds, 24);
        return OraclePriceAdjusterBalanceOut.build(
            marketValue,
            tokenInDecimals,
            tokenOutDecimals,
            oracleDecimalsA,
            isDenominatorA,
            maxStalenessA,
            oracleA,
            oracleDecimalsB,
            isDenominatorB,
            maxStalenessB,
            oracleB
        );
    }

    function _decodeFeed(
        bytes memory feeds,
        uint256 offset
    ) private pure returns (uint8 oracleDecimals, bool isDenominator, uint24 maxStaleness, address oracle) {
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(add(feeds, 0x20), offset))
        }

        uint8 config = uint8(word >> 248);
        oracleDecimals = config & 0x7f;
        isDenominator = config & 0x80 != 0;
        maxStaleness = uint24(word >> 224);
        oracle = address(uint160(word >> 64));
    }

    function buildBalanceIn(
        uint160 marketValue,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory feeds
    ) external pure returns (bytes memory) {
        return _buildBalanceIn(
            marketValue,
            tokenInDecimals,
            tokenOutDecimals,
            feeds
        );
    }

    function _buildProgram(
        bool adjustBalanceIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint128 marketPrice,
        uint8 tokenInDecimals,
        uint8 tokenOutDecimals,
        bytes memory feeds
    ) private view returns (bytes memory) {
        uint256 scale = 10 ** (
            tokenInDecimals >= tokenOutDecimals
                ? tokenInDecimals - tokenOutDecimals
                : tokenOutDecimals - tokenInDecimals
        );
        uint256 marketRate = tokenInDecimals >= tokenOutDecimals
            ? uint256(marketPrice) * scale
            : uint256(marketPrice).ceilDiv(scale);
        uint160 marketValue = adjustBalanceIn
            ? uint160(balanceOut.mulDiv(marketRate, 1e18, Math.Rounding.Ceil))
            : uint160(balanceIn.mulDiv(1e18, marketRate));
        bytes memory adjuster = adjustBalanceIn
            ? _buildBalanceIn(
                marketValue,
                tokenInDecimals,
                tokenOutDecimals,
                feeds
            )
            : _buildBalanceOut(
                marketValue,
                tokenInDecimals,
                tokenOutDecimals,
                feeds
            );

        return bytes.concat(
            StaticBalances.build(balanceIn, balanceOut),
            adjuster,
            LimitSwap.build(address(tokenA), address(tokenB))
        );
    }

    function _feed(
        PriceOracleMock oracle,
        uint8 oracleDecimals,
        bool isDenominator
    ) private pure returns (bytes memory) {
        return _feed(oracle, oracleDecimals, isDenominator, MAX_STALENESS);
    }

    function _feed(
        PriceOracleMock oracle,
        uint8 oracleDecimals,
        bool isDenominator,
        uint24 maxStaleness
    ) private pure returns (bytes memory) {
        uint8 config = oracleDecimals | (isDenominator ? uint8(1 << 7) : 0);
        return abi.encodePacked(config, maxStaleness, address(oracle));
    }

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
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

    function _buildTakerData(
        ISwapVM.Order memory order,
        bool isExactIn
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, orderHash);

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            usePermit2: false,
            threshold: "",
            to: address(this),
            hasPreTransferInCallback: false,
            signature: abi.encodePacked(r, s, v)
        }));
    }
}
