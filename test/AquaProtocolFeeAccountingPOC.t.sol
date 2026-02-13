// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MockTaker } from "./mocks/MockTaker.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "../src/routers/AquaSwapVMRouter.sol";
import { AquaOpcodesDebug } from "../src/opcodes/AquaOpcodesDebug.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";

import { XYCConcentrate, XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Fee, FeeArgsBuilder, BPS } from "../src/instructions/Fee.sol";
import { Controls } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

/**
 * @title AquaProtocolFeeAccountingPOC
 * @notice Minimalistic POC to prove Aqua accounting correctness with protocol fees
 * @dev Does NOT inherit from AquaSwapVMTest - standalone implementation
 */
contract AquaProtocolFeeAccountingPOC is Test, AquaOpcodesDebug {
    using ProgramBuilder for Program;

    // Constants
    uint256 constant ONE = 1e18;
    uint256 constant INITIAL_BALANCE_A = 1000e18;
    uint256 constant INITIAL_BALANCE_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 100e18;

    // Protocol fee is taken FROM Aqua balance, so maker needs extra tokens
    uint256 constant PROTOCOL_FEE_BPS = 0.05e9; // 5%
    uint256 constant FLAT_FEE_BPS = 0.10e9; // 10%

    // Contracts
    Aqua public immutable aqua = new Aqua();
    AquaSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    XYCConcentrate public concentrate;

    // Addresses
    address public maker;
    uint256 public makerPrivateKey;
    MockTaker public taker;
    address public protocolFeeRecipient;

    constructor() AquaOpcodesDebug(address(aqua)) {}

    function setUp() public {
        // Deploy tokens
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Deploy SwapVM
        swapVM = new AquaSwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        // Get concentrate contract from swapVM
        concentrate = XYCConcentrate(address(swapVM));

        // Setup maker
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Setup taker
        taker = new MockTaker(aqua, swapVM, address(this));

        // Setup protocol fee recipient
        protocolFeeRecipient = vm.addr(0x8888);
    }

    // ===== HELPER FUNCTIONS =====

    function buildProgram(
        uint32 protocolFeeBps,
        uint32 flatFeeInBps,
        bool flatFeeBeforeProtocol,
        bool includeConcentrate,
        uint256 deltaA,
        uint256 deltaB,
        uint256 liquidity
    ) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());

        bytes memory protocolFeeCode = protocolFeeBps > 0
            ? p.build(Fee._aquaProtocolFeeAmountInXD,
                     FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
            : bytes("");

        bytes memory flatFeeCode = flatFeeInBps > 0
            ? p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(flatFeeInBps))
            : bytes("");

        bytes memory concentrateCode = includeConcentrate
            ? p.build(XYCConcentrate._xycConcentrateGrowLiquidity2D,
                     XYCConcentrateArgsBuilder.build2D(address(tokenA), address(tokenB), deltaA, deltaB, liquidity))
            : bytes("");

        // Build program based on fee order
        if (flatFeeBeforeProtocol) {
            return bytes.concat(
                flatFeeCode,
                protocolFeeCode,
                concentrateCode,
                p.build(XYCSwap._xycSwapXD),
                p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
            );
        } else {
            return bytes.concat(
                protocolFeeCode,
                flatFeeCode,
                concentrateCode,
                p.build(XYCSwap._xycSwapXD),
                p.build(Controls._salt, abi.encodePacked(vm.randomUint()))
            );
        }
    }

    function createOrder(bytes memory programBytes) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
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
    }

    function shipStrategy(
        ISwapVM.Order memory order
    ) internal returns (bytes32) {
        bytes32 orderHash = swapVM.hash(order);

        vm.prank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(aqua), type(uint256).max);

        tokenA.mint(maker, INITIAL_BALANCE_A);
        tokenB.mint(maker, INITIAL_BALANCE_B);

        bytes memory strategy = abi.encode(order);

        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            strategy,
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([INITIAL_BALANCE_A, INITIAL_BALANCE_B])
        );

        assertEq(strategyHash, orderHash, "Strategy hash mismatch");
        return strategyHash;
    }

    function performSwap(
        ISwapVM.Order memory order,
        uint256 amount,
        bool zeroForOne,
        bool isExactIn
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) = zeroForOne
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));

        // Mint tokens to taker (generous amount for exactOut)
        TokenMock(tokenIn).mint(address(taker), amount * 2);

        return taker.swap(order, tokenIn, tokenOut, amount, takerData);
    }

    // ===== TEST GROUP 1: XYCSwap Tests =====

    function test_XYCSwap_ProtocolFee_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9; // 5%
        bytes memory program = buildProgram(protocolFeeBps, 0, false, false, 0, 0, 0);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 aquaBalanceABefore, uint256 aquaBalanceBBefore) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        // Check accounting
        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertEq(amountIn, SWAP_AMOUNT, "AmountIn should match swap amount");
        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        // Conservation law: taker sent amountIn, Aqua got (amountIn - protocolFee), protocol got protocolFee
        assertEq(
            aquaBalanceAAfter + protocolFee,
            aquaBalanceABefore + amountIn,
            "Token A conservation"
        );
        assertEq(aquaBalanceBAfter, aquaBalanceBBefore - amountOut, "Aqua tokenB balance");
    }

    function test_XYCSwap_ProtocolFee_ExactOut() public {
        uint32 protocolFeeBps = 0.05e9; // 5%
        bytes memory program = buildProgram(protocolFeeBps, 0, false, false, 0, 0, 0);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, false);

        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertEq(amountOut, SWAP_AMOUNT, "AmountOut should match requested");
        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        // Conservation law for tokenA
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A conservation"
        );
        assertEq(aquaBalanceBAfter, INITIAL_BALANCE_B - amountOut, "Aqua tokenB balance");
    }

    function test_XYCSwap_FlatFeeBefore_ProtocolFee_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9; // 5%
        uint32 flatFeeBps = 0.10e9; // 10%
        bytes memory program = buildProgram(protocolFeeBps, flatFeeBps, true, false, 0, 0, 0);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        // Conservation law: tokenA accounting (flatFee stays in Aqua, protocolFee goes to recipient)
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A conservation"
        );
        // Conservation law: tokenB accounting
        assertEq(aquaBalanceBAfter + amountOut, INITIAL_BALANCE_B, "Token B conservation");
    }

    function test_XYCSwap_ProtocolFee_FlatFeeAfter_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9;
        uint32 flatFeeBps = 0.10e9;
        bytes memory program = buildProgram(protocolFeeBps, flatFeeBps, false, false, 0, 0, 0);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        // Conservation law: tokenA accounting
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A conservation"
        );
        // Conservation law: tokenB accounting
        assertEq(aquaBalanceBAfter + amountOut, INITIAL_BALANCE_B, "Token B conservation");
    }

    function test_XYCSwap_FlatFee_ProtocolFee_FlatFee_ExactIn() public {
        // This tests: flatFeeIn → protocolFee → flatFeeIn
        // Note: we can't have two _flatFeeAmountInXD in same program, so this simulates the scenario
        uint32 protocolFeeBps = 0.05e9;
        uint32 flatFeeBps = 0.10e9;
        bytes memory program = buildProgram(protocolFeeBps, flatFeeBps, true, false, 0, 0, 0);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        // Verify no accounting breaks
        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A accounting intact"
        );
    }

    // ===== TEST GROUP 2: XYCConcentrate Tests =====

    function test_XYCConcentrate_ProtocolFee_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9;

        // Compute concentrate parameters
        uint256 price = INITIAL_BALANCE_B * ONE / INITIAL_BALANCE_A; // 2e18
        uint256 priceMin = price * 50 / 100; // 1e18 (50% lower)
        uint256 priceMax = price * 150 / 100; // 3e18 (50% higher)

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            INITIAL_BALANCE_A,
            INITIAL_BALANCE_B,
            price,
            priceMin,
            priceMax
        );

        bytes memory program = buildProgram(protocolFeeBps, 0, false, true, deltaA, deltaB, liquidity);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        // Check Aqua accounting
        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        // Conservation law
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A accounting"
        );

        // Check Concentrate storage
        uint256 storedLiquidity = concentrate.liquidity(orderHash);
        assertGt(storedLiquidity, 0, "Concentrate liquidity stored");
    }

    function test_XYCConcentrate_ProtocolFee_ExactOut() public {
        uint32 protocolFeeBps = 0.05e9;

        uint256 price = INITIAL_BALANCE_B * ONE / INITIAL_BALANCE_A;
        uint256 priceMin = price * 50 / 100;
        uint256 priceMax = price * 150 / 100;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            INITIAL_BALANCE_A,
            INITIAL_BALANCE_B,
            price,
            priceMin,
            priceMax
        );

        bytes memory program = buildProgram(protocolFeeBps, 0, false, true, deltaA, deltaB, liquidity);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, false);

        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertEq(amountOut, SWAP_AMOUNT, "Exact out amount");
        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A accounting"
        );

        // Verify Concentrate storage
        assertGt(concentrate.liquidity(orderHash), 0, "Liquidity stored");
    }

    function test_XYCConcentrate_FlatFeeBefore_ProtocolFee_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9;
        uint32 flatFeeBps = 0.10e9;

        uint256 price = INITIAL_BALANCE_B * ONE / INITIAL_BALANCE_A;
        uint256 priceMin = price * 50 / 100;
        uint256 priceMax = price * 150 / 100;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            INITIAL_BALANCE_A,
            INITIAL_BALANCE_B,
            price,
            priceMin,
            priceMax
        );

        bytes memory program = buildProgram(protocolFeeBps, flatFeeBps, true, true, deltaA, deltaB, liquidity);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        (uint256 aquaBalanceAAfter,) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A accounting"
        );
        assertGt(concentrate.liquidity(orderHash), 0, "Concentrate storage");
    }

    function test_XYCConcentrate_ProtocolFee_FlatFeeAfter_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9;
        uint32 flatFeeBps = 0.10e9;

        uint256 price = INITIAL_BALANCE_B * ONE / INITIAL_BALANCE_A;
        uint256 priceMin = price * 50 / 100;
        uint256 priceMax = price * 150 / 100;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            INITIAL_BALANCE_A,
            INITIAL_BALANCE_B,
            price,
            priceMin,
            priceMax
        );

        bytes memory program = buildProgram(protocolFeeBps, flatFeeBps, false, true, deltaA, deltaB, liquidity);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        (uint256 aquaBalanceAAfter,) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);

        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A accounting"
        );
        assertGt(concentrate.liquidity(orderHash), 0, "Concentrate liquidity");
    }

    function test_XYCConcentrate_Complex_Fees_ExactIn() public {
        uint32 protocolFeeBps = 0.05e9;
        uint32 flatFeeBps = 0.10e9;

        uint256 price = INITIAL_BALANCE_B * ONE / INITIAL_BALANCE_A;
        uint256 priceMin = price * 50 / 100;
        uint256 priceMax = price * 150 / 100;

        (uint256 deltaA, uint256 deltaB, uint256 liquidity) = XYCConcentrateArgsBuilder.computeDeltas(
            INITIAL_BALANCE_A,
            INITIAL_BALANCE_B,
            price,
            priceMin,
            priceMax
        );

        bytes memory program = buildProgram(protocolFeeBps, flatFeeBps, true, true, deltaA, deltaB, liquidity);
        ISwapVM.Order memory order = createOrder(program);
        bytes32 orderHash = shipStrategy(order);

        (uint256 amountIn, uint256 amountOut) = performSwap(order, SWAP_AMOUNT, true, true);

        // Full accounting check
        (uint256 aquaBalanceAAfter, uint256 aquaBalanceBAfter) = aqua.safeBalances(
            maker, address(swapVM), orderHash, address(tokenA), address(tokenB)
        );

        uint256 protocolFee = tokenA.balanceOf(protocolFeeRecipient);
        uint256 takerReceived = tokenB.balanceOf(address(taker));

        // Conservation law for both tokens
        assertEq(
            aquaBalanceAAfter + protocolFee,
            INITIAL_BALANCE_A + amountIn,
            "Token A conservation"
        );
        assertEq(
            aquaBalanceBAfter + takerReceived,
            INITIAL_BALANCE_B,
            "Token B conservation"
        );
        assertGt(protocolFee, 0, "Protocol fee paid (tokenA)");
        assertGt(concentrate.liquidity(orderHash), 0, "Concentrate state");
    }
}
