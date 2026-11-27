// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { Opcode } from "../../contracts/libs/OpcodeList.sol";
import { InstructionBuilder } from "../../contracts/libs/InstructionBuilder.sol";
import { MakerTraits, MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { StaticBalances, DynamicBalances } from "../../contracts/instructions/Balances.sol";
import { BaseFeeAdjuster } from "../../contracts/instructions/BaseFeeAdjuster.sol";
import { Deadline } from "../../contracts/instructions/Controls.sol";
import { Decay } from "../../contracts/instructions/Decay.sol";
import { DutchAuction } from "../../contracts/instructions/DutchAuction.sol";
import { Extruction } from "../../contracts/instructions/Extruction.sol";
import { FeeFlatIn, FeeFlatOut } from "../../contracts/instructions/FeeFlat.sol";
import { FeeProtocol, FeeProtocolSurplus } from "../../contracts/instructions/FeeProtocol.sol";
import { FillGridAdjuster } from "../../contracts/instructions/FillGridAdjuster.sol";
import { InvalidateBit } from "../../contracts/instructions/Invalidators.sol";
import { Jump, JumpIfDirection, JumpIfTokenIn, JumpIfTokenOut } from "../../contracts/instructions/Jumps.sol";
import { LimitSwap, LimitSwapFullAmount } from "../../contracts/instructions/LimitSwap.sol";
import { RequireMinRate } from "../../contracts/instructions/MinRate.sol";
import { OraclePriceAdjuster } from "../../contracts/instructions/OraclePriceAdjuster.sol";
import { PeggedSwap } from "../../contracts/instructions/PeggedSwap.sol";
import { PiecewiseLinearSurcharge } from "../../contracts/instructions/PiecewiseLinearSurcharge.sol";
import { ValidateSeriesEpoch } from "../../contracts/instructions/SeriesEpochManager.sol";
import {
    OnlyTakerTokenBalanceNonZero,
    OnlyTxOriginTokenBalanceNonZero,
    OnlyTakerTokenBalanceGte,
    OnlyTakerTokenSupplyShareGte
} from "../../contracts/instructions/TokenValidators.sol";
import { PrivateOrder, WhitelistCoequal, WhitelistSequential } from "../../contracts/instructions/Whitelist.sol";
import { XYCConcentrateSwap } from "../../contracts/instructions/XYCConcentrate.sol";

/// @title Order data bounds tests
/// @notice Execution depends only on the bytes covered by the order hash: instructions reject args of unexpected length
///   and order data slices never reach calldata that follows `order.data`
contract ArgsLengthTest is Test {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant BALANCE_A = 1000e18;
    uint256 constant BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    bytes4 internal immutable MISMATCH = InstructionBuilder.InstructionBuilderArgsLengthMismatch.selector;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        tokenA.mint(taker, 10000e18);
        tokenB.mint(taker, 10000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    // ============================================
    // Instruction args length
    // ============================================

    function test_ArgsLength_Balances() public {
        _assertExactLength(StaticBalances.build(BALANCE_A, BALANCE_B));
        _assertExactLength(DynamicBalances.build(BALANCE_A, BALANCE_B));
    }

    function test_ArgsLength_ControlsAndJumps() public {
        _assertExactLength(Deadline.build(uint40(block.timestamp + 1)));
        _assertExactLength(Jump.build(0));
        _assertExactLength(JumpIfDirection.build(true, 0));
        _assertExactLength(JumpIfTokenIn.build(address(tokenA), 0));
        _assertExactLength(JumpIfTokenOut.build(address(tokenA), 0));
    }

    function test_ArgsLength_Guards() public {
        _assertExactLength(PrivateOrder.build(taker));
        _assertExactLength(OnlyTakerTokenBalanceNonZero.build(address(tokenA)));
        _assertExactLength(OnlyTxOriginTokenBalanceNonZero.build(address(tokenA)));
        _assertExactLength(OnlyTakerTokenBalanceGte.build(address(tokenA), 1));
        _assertExactLength(OnlyTakerTokenSupplyShareGte.build(address(tokenA), 1));
        _assertExactLength(InvalidateBit.build(1));
        _assertExactLength(ValidateSeriesEpoch.build(1, 0));
        _assertExactLength(RequireMinRate.build(1, 1));
    }

    function test_ArgsLength_Curves() public {
        _assertExactLength(LimitSwap.build(true));
        _assertExactLength(LimitSwapFullAmount.build(true));
        _assertExactLength(PeggedSwap.build(1e27, 1e27, 1e27));
        _assertExactLength(XYCConcentrateSwap.build(1e18, 2e18));
        _assertExactLength(Decay.build(300));
    }

    function test_ArgsLength_FeesAndAdjusters() public {
        _assertExactLength(FeeFlatIn.build(1e5));
        _assertExactLength(FeeFlatOut.build(1e5));
        _assertExactLength(FeeProtocolSurplus.build(true, 1e18));
        _assertExactLength(DutchAuction.build(true, uint40(block.timestamp), 0.999e18, 1e5));
        _assertExactLength(BaseFeeAdjuster.build(true, 1 gwei, 3000e18, 150_000));
    }

    function test_ArgsLength_Whitelists() public {
        address[] memory takers = new address[](1);
        takers[0] = taker;
        uint16[] memory durations = new uint16[](1);
        durations[0] = 60;

        bytes memory coequal = WhitelistCoequal.build(0, takers);
        _assertExactLength(coequal);
        _assertMismatch(_resize(coequal, 2)); // no takers

        bytes memory sequential = WhitelistSequential.build(uint40(block.timestamp), 0, takers, durations);
        _assertExactLength(sequential);
        _assertMismatch(_resize(sequential, 5 + 2)); // no takers
    }

    function test_ArgsLength_PiecewiseLinearSurcharge() public {
        uint16[] memory durations = new uint16[](1);
        durations[0] = 60;
        uint24[] memory scales = new uint24[](2);
        scales[0] = 1 << 23;

        bytes memory instruction = PiecewiseLinearSurcharge.build(true, uint40(block.timestamp), durations, scales);
        _assertExactLength(instruction);
        _assertMismatch(_resize(instruction, 1 + 5 + 3)); // no intervals
    }

    function test_ArgsLength_FillGridAdjuster() public {
        bytes memory instruction = FillGridAdjuster.build(true, new uint24[](1), new uint24[](1));
        _assertExactLength(instruction);
        _assertMismatch(_resize(instruction, 1)); // no points

        // Hand-encoded grid starting above zero: [opcode, length, adjustIn, uint24 fillBps, uint24 adjustBps]
        instruction[5] = 0x01;
        ISwapVM.Order memory order = _createOrder(instruction);
        bytes memory takerData = _takerData("");
        vm.expectRevert(FillGridAdjuster.FillGridAdjusterInvalidGridStart.selector);
        swapVM.quote(order, SWAP_AMOUNT, takerData);
    }

    function test_ArgsLength_OraclePriceAdjuster() public {
        OraclePriceAdjuster.Feed[] memory feeds = new OraclePriceAdjuster.Feed[](1);
        feeds[0] = OraclePriceAdjuster.Feed({ oracleDecimals: 8, isDenominator: false, maxStaleness: 3600, oracle: address(0xfeed) });

        bytes memory instruction = OraclePriceAdjuster.build(true, 1e18, 18, 18, feeds);
        _assertExactLength(instruction);
        _assertMismatch(_resize(instruction, 22)); // no feeds
        _assertMismatch(_resize(instruction, 22 + 3 * 23)); // three feeds
    }

    function test_ArgsLength_FeeProtocol() public {
        FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](1);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: address(0xfee), feeBps: 1e5, surplusBps: 0 });

        bytes memory instruction = FeeProtocol.build(true, receivers, new FeeProtocol.ProviderConfig[](0));
        _assertExactLength(instruction);
        _assertMismatch(_resize(instruction, 0)); // header byte missing
    }

    function test_ArgsLength_Extruction() public {
        bytes memory instruction = Extruction.build(address(0xdead), "");
        _assertMismatch(_resize(instruction, 19)); // target cut
    }

    // ============================================
    // Underlength last instruction, missing bytes supplied by the taker after `order.data`
    // ============================================

    function test_UnsignedTail_IgnoredForWellFormedOrder() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_A, BALANCE_B),
            LimitSwap.build(address(tokenA), address(tokenB)),
            PrivateOrder.build(taker)
        ));

        (uint256 amountIn, uint256 amountOut,) = swapVM.quote(order, SWAP_AMOUNT, _takerData(""));
        (bool success, bytes memory result) = _quoteWithTail(order, taker, hex"ffffffffffffff");
        assertTrue(success);
        (uint256 tailAmountIn, uint256 tailAmountOut,) = abi.decode(result, (uint256, uint256, bytes32));
        assertEq(tailAmountIn, amountIn);
        assertEq(tailAmountOut, amountOut);
    }

    function test_UnsignedTail_PrivateOrderTaker() public {
        address stranger = makeAddr("stranger");
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_A, BALANCE_B),
            LimitSwap.build(address(tokenA), address(tokenB)),
            _header(PrivateOrder.opcode)
        ));

        (bool success, bytes memory result) = _quoteWithTail(order, stranger, abi.encodePacked(uint80(uint160(stranger))));
        assertFalse(success, "taker allowed by bytes out of order.data");
        assertEq(bytes4(result), MISMATCH);
    }

    function test_UnsignedTail_LimitSwapDirection() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_A, BALANCE_B),
            _header(LimitSwap.opcode)
        ));

        (bool success, bytes memory result) = _quoteWithTail(order, taker, hex"80");
        assertFalse(success, "direction set by bytes out of order.data");
        assertEq(bytes4(result), MISMATCH);
    }

    function test_UnsignedTail_JumpTarget() public {
        bytes memory program = bytes.concat(
            StaticBalances.build(BALANCE_A, BALANCE_B),
            LimitSwap.build(address(tokenA), address(tokenB)),
            _header(Jump.opcode)
        );
        ISwapVM.Order memory order = _createOrder(program);

        (bool success, bytes memory result) = _quoteWithTail(order, taker, abi.encodePacked(uint16(program.length)));
        assertFalse(success, "jump target set by bytes out of order.data");
        assertEq(bytes4(result), MISMATCH);
    }

    function test_UnsignedTail_InvalidateBitIndex() public {
        ISwapVM.Order memory order = _createOrder(bytes.concat(
            StaticBalances.build(BALANCE_A, BALANCE_B),
            LimitSwap.build(address(tokenA), address(tokenB)),
            _header(InvalidateBit.opcode)
        ));

        (bool success, bytes memory result) = _quoteWithTail(order, taker, abi.encodePacked(uint32(777)));
        assertFalse(success, "bit index set by bytes out of order.data");
        assertEq(bytes4(result), MISMATCH);
    }

    // ============================================
    // Order data slices
    // ============================================

    function test_OrderData_ProgramOffsetBeyondData() public {
        ISwapVM.Order memory order = _createOrder("");
        // Program slice offset is `order.data.length + 1`, the maker signs traits pointing out of the data
        order.traits = MakerTraits.wrap(MakerTraits.unwrap(order.traits) + (1 << 208));

        // Taker places an own program right after `order.data`: 1 wei of token A buys 1000 token B
        bytes memory dataArea = bytes.concat(
            order.data,
            hex"00",
            StaticBalances.build(1, 1000e18),
            LimitSwap.build(address(tokenA), address(tokenB))
        );
        dataArea = bytes.concat(dataArea, new bytes(160 - dataArea.length));

        bytes memory takerData = _takerData(_sign(order));
        bytes memory callData = abi.encodePacked(
            ISwapVM.swap.selector,
            uint256(0x60), uint256(1), uint256(0x60 + 0x60 + 0x20 + dataArea.length),
            uint256(uint160(order.maker)), MakerTraits.unwrap(order.traits), uint256(0x60), order.data.length, dataArea,
            takerData.length, takerData, new bytes(32)
        );

        uint256 makerBalanceB = tokenB.balanceOf(maker);
        (bool success, bytes memory result) = address(swapVM).call(callData);
        assertFalse(success, "program taken from bytes out of order.data");
        assertEq(bytes4(result), MakerTraitsLib.MakerTraitsMissingHookData.selector);
        assertEq(tokenB.balanceOf(maker), makerBalanceB);
    }

    function test_OrderData_MissingTokens() public {
        ISwapVM.Order memory order = ISwapVM.Order({ maker: maker, traits: MakerTraits.wrap(0), data: new bytes(39) });
        bytes memory takerData = _takerData("");

        vm.expectRevert(MakerTraitsLib.MakerTraitsMissingTokens.selector);
        swapVM.quote(order, SWAP_AMOUNT, takerData);
    }

    // ============================================
    // Helpers
    // ============================================

    /// @dev Instruction of one args byte less and one args byte more should both be rejected
    function _assertExactLength(bytes memory instruction) private {
        _assertMismatch(_resize(instruction, instruction.length - 3));
        _assertMismatch(_resize(instruction, instruction.length - 1));
    }

    function _assertMismatch(bytes memory program) private {
        ISwapVM.Order memory order = _createOrder(program);
        bytes memory takerData = _takerData("");

        vm.expectRevert(MISMATCH);
        swapVM.quote(order, SWAP_AMOUNT, takerData);
    }

    /// @dev Cut or zero-extend instruction args to `argsLength` and patch the header accordingly
    function _resize(bytes memory instruction, uint256 argsLength) private pure returns (bytes memory resized) {
        resized = new bytes(2 + argsLength);
        for (uint256 i; i < resized.length && i < instruction.length; i++) resized[i] = instruction[i];
        resized[1] = bytes1(uint8(argsLength));
    }

    /// @dev Instruction header declaring no args
    function _header(Opcode opcode) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(opcode), uint8(0));
    }

    /// @dev Standard ABI encoding of `quote` with the zero padding that follows `order.data` replaced by `tail`
    function _quoteWithTail(
        ISwapVM.Order memory order,
        address sender,
        bytes memory tail
    ) private returns (bool success, bytes memory result) {
        bytes memory callData = abi.encodeCall(ISwapVM.quote, (order, SWAP_AMOUNT, _takerData("")));

        // selector, 3 head words, 3 order head words, data length word
        uint256 dataEnd = 4 + 0x60 + 0x60 + 0x20 + order.data.length;
        assertGe((32 - order.data.length % 32) % 32, tail.length, "tail exceeds ABI padding");
        for (uint256 i; i < tail.length; i++) callData[dataEnd + i] = tail[i];

        vm.prank(sender);
        (success, result) = address(swapVM).call(callData);
    }

    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
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

    function _sign(ISwapVM.Order memory order) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        return abi.encodePacked(r, s, v);
    }

    function _takerData(bytes memory signature) private view returns (bytes memory) {
        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: true,
            allowPartialFill: false,
            usePermit2: false,
            threshold: "",
            to: taker,
            hasPreTransferInCallback: false,
            signature: signature
        }));
    }
}
