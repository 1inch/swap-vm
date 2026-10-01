// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./helpers/SwapVMTestSetup.sol";
import { StaticBalances, DynamicBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";
import { RequireMinRate } from "../../contracts/instructions/MinRate.sol";
import { FeeFlatIn, FeeFlatOut } from "../../contracts/instructions/FeeFlat.sol";

/**
 * @title MinRateTest
 * @notice Functional tests for MinRate instruction
 * @dev Tests minimum rate enforcement and adjustment mechanics
 */
contract MinRateTest is Test {
    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TraitsHelper internal orders;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        orders = DeployCode.TraitsHelper();
        swapVM = DeployCode.SwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 10000e18);
        tokenB.mint(maker, 10000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    /**
     * Test requireMinRate with passing rate
     */
    function test_RequireMinRatePass() public {
        // Setup: 1 tokenA = 2 tokenB base rate
        // MinRate: require at most 1 tokenA : 2.2 tokenB (maker protection)
        uint64 rateA = 1e18;
        uint64 rateB = 2.2e18;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            RequireMinRate.build(rateA, rateB),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0, true);

        // Should succeed - rate is 2:1 which doesn't exceed the max 1:2.2
        uint256 amountOut = _executeSwap(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            1e18,
            exactInData
        );

        assertEq(amountOut, 2e18, "Should get base rate output");
    }

    /**
     * Test requireMinRate with failing rate
     */
    function test_RequireMinRateRevert() public {
        // Setup: 1 tokenA = 2 tokenB base rate
        // MinRate: require at most 1 tokenA : 1.5 tokenB (maker protection)
        uint64 rateA = 1e18;
        uint64 rateB = 1.5e18;

        bytes memory bytecode = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            RequireMinRate.build(rateA, rateB),
            LimitSwap.build(address(tokenA), address(tokenB))
        );

        ISwapVM.Order memory order = _createOrder(bytecode);
        bytes memory exactInData = _signAndPackTakerData(order, true, 0, true);

        // Mock the input tokens
        TokenMock(address(tokenA)).mint(taker, 1e18);

        // Should revert - rate is 2:1 which exceeds the max 1:1.5
        vm.expectRevert();
        swapVM.swap(
            order,
            1e18,
            exactInData
        );
    }

    // Helper functions
    function _executeSwap(
        SwapVMRouter _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal returns (uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            amount,
            takerData
        );

        // Verify the swap consumed the expected input amount
        require(actualIn == amount, "Unexpected input amount consumed");

        return actualOut;
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

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold,
        bool isAToB
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            isAToB: isAToB,
            allowPartialFill: false,
            usePermit2: false,
            threshold: thresholdData,
            to: address(this),
            hasPreTransferInCallback: false,
            signature: signature
        }));
    }
}
