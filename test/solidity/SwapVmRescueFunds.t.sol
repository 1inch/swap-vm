// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVMRouter, DeployCode } from "./helpers/SwapVMTestSetup.sol";

/// @dev Smoke test: Rescuable edge cases are covered in solidity-utils
contract SwapVmRescueFundsTest is Test {
    SwapVMRouter public swapVM;
    TokenMock public tokenA;

    function setUp() public {
        swapVM = DeployCode.SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token I", "TKI");
    }

    function test_RescueFunds_ERC20() public {
        uint256 amount = 50e18;
        tokenA.mint(address(swapVM), amount);

        uint256 ownerBalanceBefore = tokenA.balanceOf(address(this));
        swapVM.rescueFunds(address(tokenA), amount);
        assertEq(tokenA.balanceOf(address(this)) - ownerBalanceBefore, amount);
        assertEq(tokenA.balanceOf(address(swapVM)), 0);
    }
}
