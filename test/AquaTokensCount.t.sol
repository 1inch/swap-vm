// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVM } from "../src/SwapVM.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";

import { Program, ProgramBuilder, Opcode } from "./utils/ProgramBuilder.sol";
import { dynamic } from "./utils/Dynamic.sol";

import { AquaSwapVMTest } from "./base/AquaSwapVMTest.sol";

/**
 * @title AquaTokensCountTest
 * @notice SwapVM must deny execution of Aqua strategies whose traded tokens
 *         were not shipped in a batch of exactly 2 tokens
 */
contract AquaTokensCountTest is AquaSwapVMTest {
    using ProgramBuilder for Program;

    uint256 constant BALANCE_A = 1000e18;
    uint256 constant BALANCE_B = 1000e18;
    uint256 constant SWAP_AMOUNT = 10e18;

    TokenMock public tokenC;

    ISwapVM.Order internal order;
    bytes internal strategy;

    function setUp() public override {
        super.setUp();

        tokenC = new TokenMock("Token K", "TKK");

        Program p;
        order = createStrategy(bytes.concat(
            p.build(Opcode.XYCSwap),
            p.build(Opcode.Salt, abi.encodePacked(vm.randomUint()))
        ));
        strategy = abi.encode(order);

        vm.startPrank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        tokenC.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        tokenA.mint(maker, BALANCE_A);
        tokenB.mint(maker, BALANCE_B);
    }

    function _ship(address[] memory tokens, uint256[] memory amounts) internal {
        vm.prank(maker);
        aqua.ship(address(swapVM), strategy, tokens, amounts);
    }

    function _swapProgram(bool zeroForOne) internal view returns (SwapProgram memory) {
        return SwapProgram({
            amount: SWAP_AMOUNT,
            taker: taker,
            tokenA: tokenA,
            tokenB: tokenB,
            zeroForOne: zeroForOne,
            isExactIn: true
        });
    }

    function _expectDenied(address token, uint256 tokensCount) internal {
        vm.expectRevert(abi.encodeWithSelector(SwapVM.AquaStrategyMustHaveExactly2Tokens.selector, token, tokensCount));
    }

    function test_Swap_2TokensStrategy_Succeeds() public {
        _ship(dynamic([address(tokenA), address(tokenB)]), dynamic([BALANCE_A, BALANCE_B]));

        SwapProgram memory swapProgram = _swapProgram(true);
        mintTokenInToTaker(swapProgram);

        (uint256 quotedIn, uint256 quotedOut) = quote(swapProgram, order);
        assertEq(quotedIn, SWAP_AMOUNT, "quoted amountIn");
        assertGt(quotedOut, 0, "quoted amountOut");

        (uint256 amountIn, uint256 amountOut) = swap(swapProgram, order);
        assertEq(amountIn, SWAP_AMOUNT, "swapped amountIn");
        assertEq(amountOut, quotedOut, "swapped amountOut");
    }

    function test_Swap_3TokensStrategy_Reverts() public {
        _ship(
            dynamic([address(tokenA), address(tokenB), address(tokenC)]),
            dynamic([BALANCE_A, BALANCE_B, uint256(1e18)])
        );

        _expectDenied(address(tokenA), 3);
        swap(_swapProgram(true), order);

        _expectDenied(address(tokenB), 3);
        swap(_swapProgram(false), order);
    }

    function test_Quote_3TokensStrategy_Reverts() public {
        _ship(
            dynamic([address(tokenA), address(tokenB), address(tokenC)]),
            dynamic([BALANCE_A, BALANCE_B, uint256(1e18)])
        );

        ISwapVM swapVMView = swapVM.asView();
        bytes memory data = takerData(address(taker), true, true);

        _expectDenied(address(tokenA), 3);
        swapVMView.quote(order, SWAP_AMOUNT, data);
    }

    function test_Swap_SplitShippedStrategy_Reverts() public {
        // Same strategy hash shipped as two single-token batches: slots read tokensCount == 1
        _ship(dynamic([address(tokenA)]), dynamic([BALANCE_A]));
        _ship(dynamic([address(tokenB)]), dynamic([BALANCE_B]));

        _expectDenied(address(tokenA), 1);
        swap(_swapProgram(true), order);
    }

    function test_Swap_DockedStrategy_Reverts() public {
        _ship(dynamic([address(tokenA), address(tokenB)]), dynamic([BALANCE_A, BALANCE_B]));

        bytes32 orderHash = swapVM.hash(order);
        vm.prank(maker);
        aqua.dock(address(swapVM), orderHash, dynamic([address(tokenA), address(tokenB)]));

        _expectDenied(address(tokenA), 0xff);
        swap(_swapProgram(true), order);
    }

    function test_Swap_UnshippedStrategy_Reverts() public {
        _expectDenied(address(tokenA), 0);
        swap(_swapProgram(true), order);
    }
}
