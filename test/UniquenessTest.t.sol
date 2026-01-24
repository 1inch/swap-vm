// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

contract UniquenessTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    TokenMock public tokenC;
    TokenMock public tokenD;

    function setUp() public override {
        super.setUp();

        // Create additional tokens C and D for the second strategy
        tokenC = new TokenMock("Token C", "TKC");
        tokenD = new TokenMock("Token D", "TKD");
    }

    /**
     * @notice Helper function to create a simple program with only _xycSwap instruction
     * @dev This ensures both strategies have identical programs and thus identical orderHashes
     */
    function buildSimpleXYCProgram(uint64 salt) internal pure returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            salt > 0 ? p.build(Controls._salt, ControlsArgsBuilder.buildSalt(salt)) : bytes("")
        );
    }

    /**
     * @notice WARNING: This test demonstrates a DANGEROUS scenario that should be avoided in production!
     * @dev Two strategies with the same program but different token sets share the same orderHash.
     *      This creates a security risk where LPs can lose funds because takers can swap between
     *      different token pairs using the same strategy hash.
     *
     *      RECOMMENDATION: Always use the _salt instruction to make strategy hashes unique.
     *      This ensures each strategy has its own isolated liquidity pool and prevents
     *      unintended cross-token swaps that could lead to fund loss for LPs.
     *
     *      This test exists solely to demonstrate the risk and verify the system behavior,
     *      NOT as a recommended practice.
     */
    function test_SameHash_DifferentTokens_TakerCanSwap() public {
        // Build identical programs for both strategies
        bytes memory programBytes = buildSimpleXYCProgram(0);

        // Create first strategy with tokens A and B
        ISwapVM.Order memory strategy1 = createStrategy(programBytes);

        // Create second strategy with the same program (will have same orderHash)
        ISwapVM.Order memory strategy2 = createStrategy(programBytes);

        // Calculate orderHash for both strategies
        bytes32 orderHash1 = swapVM.hash(strategy1);
        bytes32 orderHash2 = swapVM.hash(strategy2);

        // Verify that both strategies have the same orderHash
        assertEq(orderHash1, orderHash2, "Strategies with same program should have same orderHash");

        // Ship first strategy with tokens A and B
        uint256 balanceA1 = 1000e18;
        uint256 balanceB1 = 2000e18;
        bytes32 strategyHash1 = shipStrategy(strategy1, tokenA, tokenB, balanceA1, balanceB1);

        // Ship second strategy with tokens C and D
        uint256 balanceC2 = 1500e18;
        uint256 balanceD2 = 3000e18;

        // Mint tokens C and D to maker
        tokenC.mint(maker, balanceC2);
        tokenD.mint(maker, balanceD2);

        vm.prank(maker);
        tokenC.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenD.approve(address(aqua), type(uint256).max);

        bytes memory strategy2Data = abi.encode(strategy2);
        address[] memory tokens2 = new address[](2);
        tokens2[0] = address(tokenC);
        tokens2[1] = address(tokenD);
        uint256[] memory balances2 = new uint256[](2);
        balances2[0] = balanceC2;
        balances2[1] = balanceD2;

        vm.prank(maker);
        bytes32 strategyHash2 = aqua.ship(
            address(swapVM),
            strategy2Data,
            tokens2,
            balances2
        );

        // Verify both strategies have the same hash
        assertEq(strategyHash1, strategyHash2, "Both strategies should have the same hash");
        assertEq(strategyHash1, orderHash1, "Strategy hash should equal order hash");

        // Verify initial balances for strategy 1 (A, B tokens)
        (uint256 aquaBalanceA1, uint256 aquaBalanceB1) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash1,
            address(tokenA),
            address(tokenB)
        );
        assertEq(aquaBalanceA1, balanceA1, "Strategy 1 should have correct tokenA balance");
        assertEq(aquaBalanceB1, balanceB1, "Strategy 1 should have correct tokenB balance");

        // Verify initial balances for strategy 2 (C, D tokens)
        (uint256 aquaBalanceC2, uint256 aquaBalanceD2) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash2,
            address(tokenC),
            address(tokenD)
        );
        assertEq(aquaBalanceC2, balanceC2, "Strategy 2 should have correct tokenC balance");
        assertEq(aquaBalanceD2, balanceD2, "Strategy 2 should have correct tokenD balance");

        // Perform swap on strategy 1 (A -> B)
        uint256 swapAmountA = 100e18;
        SwapProgram memory swapProgram1 = SwapProgram({
            amount: swapAmountA,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: true,
            isExactIn: true
        });

        mintTokenInToTaker(swapProgram1);
        mintTokenOutToMaker(swapProgram1, 200e18);

        (uint256 amountIn1, uint256 amountOut1) = swap(swapProgram1, strategy1);

        assertGt(amountIn1, 0, "Swap 1: amountIn should be greater than 0");
        assertGt(amountOut1, 0, "Swap 1: amountOut should be greater than 0");

        // Verify balances changed for strategy 1
        (uint256 aquaBalanceA1After, uint256 aquaBalanceB1After) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash1,
            address(tokenA),
            address(tokenB)
        );
        assertEq(aquaBalanceA1After, balanceA1 + amountIn1, "Strategy 1 tokenA balance should increase");
        assertEq(aquaBalanceB1After, balanceB1 - amountOut1, "Strategy 1 tokenB balance should decrease");

        // Perform swap on strategy 2 (C -> D)
        uint256 swapAmountC = 150e18;

        // Mint tokens C to taker
        tokenC.mint(address(taker), swapAmountC);

        // Mint tokens D to maker for liquidity
        tokenD.mint(maker, 300e18);

        SwapProgram memory swapProgram2 = SwapProgram({
            amount: swapAmountC,
            taker: taker,
            tokenA: tokenC,
            tokenB: tokenD,
            zeroForOne: true,
            isExactIn: true
        });

        (uint256 amountIn2, uint256 amountOut2) = swap(swapProgram2, strategy2);

        assertGt(amountIn2, 0, "Swap 2: amountIn should be greater than 0");
        assertGt(amountOut2, 0, "Swap 2: amountOut should be greater than 0");

        // Verify balances changed for strategy 2
        (uint256 aquaBalanceC2After, uint256 aquaBalanceD2After) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash2,
            address(tokenC),
            address(tokenD)
        );
        assertEq(aquaBalanceC2After, balanceC2 + amountIn2, "Strategy 2 tokenC balance should increase");
        assertEq(aquaBalanceD2After, balanceD2 - amountOut2, "Strategy 2 tokenD balance should decrease");

        // Verify that strategy 1 balances remain unchanged after strategy 2 swap
        (uint256 aquaBalanceA1Final, uint256 aquaBalanceB1Final) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash1,
            address(tokenA),
            address(tokenB)
        );
        assertEq(aquaBalanceA1Final, aquaBalanceA1After, "Strategy 1 tokenA should not change");
        assertEq(aquaBalanceB1Final, aquaBalanceB1After, "Strategy 1 tokenB should not change");

        // Perform cross-strategy swap: B -> C
        // This demonstrates that taker can swap between different token sets using the same orderHash
        uint256 swapAmountB = 50e18;

        // Get current balances before cross-strategy swap
        (uint256 aquaBalanceBBeforeBC, uint256 aquaBalanceCBeforeBC) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash1,
            address(tokenB),
            address(tokenC)
        );

        // Mint tokenB to taker
        tokenB.mint(address(taker), swapAmountB);

        // Mint tokenC to maker for liquidity
        tokenC.mint(maker, 100e18);

        SwapProgram memory swapProgramBC = SwapProgram({
            amount: swapAmountB,
            taker: taker,
            tokenA: tokenB,
            tokenB: tokenC,
            zeroForOne: true,
            isExactIn: true
        });

        (uint256 amountInBC, uint256 amountOutBC) = swap(swapProgramBC, strategy1);

        assertGt(amountInBC, 0, "Cross-strategy swap: amountIn should be greater than 0");
        assertGt(amountOutBC, 0, "Cross-strategy swap: amountOut should be greater than 0");

        // Verify balances changed for cross-strategy swap (B from strategy1, C from strategy2)
        (uint256 aquaBalanceB1FinalBC, uint256 aquaBalanceC1FinalBC) = aqua.safeBalances(
            maker,
            address(swapVM),
            strategyHash1,
            address(tokenB),
            address(tokenC)
        );
        assertEq(aquaBalanceB1FinalBC, aquaBalanceBBeforeBC + amountInBC, "TokenB balance should increase");
        assertEq(aquaBalanceC1FinalBC, aquaBalanceCBeforeBC - amountOutBC, "TokenC balance should decrease");
    }

    /**
     * @notice RECOMMENDED PRACTICE: This test demonstrates the correct way to create strategies with unique hashes
     * @dev Two strategies use different salt values (salt=1 and salt=2) via the _salt instruction,
     *      ensuring each strategy has a unique orderHash even though they use the same base program.
     *
     *      This is the RECOMMENDED approach for LPs:
     *      - Each strategy gets its own isolated liquidity pool
     *      - Prevents unintended cross-token swaps
     *      - Protects LP funds from being accessed by other token pairs
     *      - The _salt instruction makes each strategy hash unique
     *
     *      The test verifies that when strategies have different hashes (due to different salts),
     *      a taker cannot swap between token sets that belong to different strategies.
     */
    function test_SameHash_DifferentTokens_TakerCanNotSwap() public {
        // Create first strategy with tokens A and B
        ISwapVM.Order memory strategy1 = createStrategy(buildSimpleXYCProgram(1));

        // Create second strategy with a different salt (will have a different orderHash)
        ISwapVM.Order memory strategy2 = createStrategy(buildSimpleXYCProgram(2));

        // Calculate orderHash for both strategies
        bytes32 orderHash1 = swapVM.hash(strategy1);
        bytes32 orderHash2 = swapVM.hash(strategy2);

        // Verify that both strategies have the same orderHash
        assertNotEq(orderHash1, orderHash2, "Strategies with same program should not have same orderHash");

        // Ship first strategy with tokens A and B
        uint256 balanceA1 = 1000e18;
        uint256 balanceB1 = 2000e18;
        bytes32 strategyHash1 = shipStrategy(strategy1, tokenA, tokenB, balanceA1, balanceB1);

        // Ship second strategy with tokens C and D
        uint256 balanceC2 = 1500e18;
        uint256 balanceD2 = 3000e18;

        // Mint tokens C and D to maker
        tokenC.mint(maker, balanceC2);
        tokenD.mint(maker, balanceD2);

        vm.prank(maker);
        tokenC.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenD.approve(address(aqua), type(uint256).max);

        bytes memory strategy2Data = abi.encode(strategy2);
        address[] memory tokens2 = new address[](2);
        tokens2[0] = address(tokenC);
        tokens2[1] = address(tokenD);
        uint256[] memory balances2 = new uint256[](2);
        balances2[0] = balanceC2;
        balances2[1] = balanceD2;

        vm.prank(maker);
        bytes32 strategyHash2 = aqua.ship(
            address(swapVM),
            strategy2Data,
            tokens2,
            balances2
        );

        // Verify both strategies have different hashes
        assertNotEq(strategyHash1, strategyHash2, "Both strategies should not have the same hash");
        assertEq(strategyHash1, orderHash1, "Strategy hash should equal order hash");

        // Attempt cross-strategy swap: B -> C
        // This demonstrates that a cross-strategy swap is prevented when strategies have different (unique) orderHashes,
        // reverting with SafeBalancesForTokenNotInActiveStrategy to protect against using balances from another strategy.
        uint256 swapAmountB = 50e18;

        // Mint tokenB to taker
        tokenB.mint(address(taker), swapAmountB);
        // Mint tokenC to maker for liquidity
        tokenC.mint(maker, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
                address(maker),
                address(swapVM),
                strategyHash1,
                address(tokenC)
            )
        );
        swap(SwapProgram({
            amount: swapAmountB,
            taker: taker,
            tokenA: tokenB,
            tokenB: tokenC,
            zeroForOne: true,
            isExactIn: true
        }), strategy1);
    }
}
