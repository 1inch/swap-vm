// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { SwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { NoReceive } from "./mocks/NoReceive.sol";

contract SwapVmRescueFundsTest is Test, OpcodesDebug {
    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;

    function setUp() public {
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
    }

    function test_RescueFunds_ERC20() public {
        uint256 amount = 50e18;
        tokenA.mint(address(swapVM), amount);

        uint256 ownerBalanceBefore = tokenA.balanceOf(address(this));
        swapVM.rescueFunds(IERC20(address(tokenA)), amount);
        assertEq(tokenA.balanceOf(address(this)) - ownerBalanceBefore, amount);
        assertEq(tokenA.balanceOf(address(swapVM)), 0);
    }

    function test_RescueFunds_ETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(swapVM), amount);

        uint256 ownerBalanceBefore = address(this).balance;
        swapVM.rescueFunds(IERC20(address(0)), amount);
        assertEq(address(this).balance - ownerBalanceBefore, amount);
        assertEq(address(swapVM).balance, 0);
    }

    function test_RescueFunds_RevertsIfNotOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        swapVM.rescueFunds(IERC20(address(tokenA)), 1e18);
    }

    function test_RescueFunds_ETH_RevertsIfTransferFails() public {
        uint256 amount = 1 ether;
        vm.deal(address(swapVM), amount);

        address noReceive = address(new NoReceive());
        swapVM.transferOwnership(noReceive);

        vm.prank(noReceive);
        vm.expectRevert(abi.encodeWithSelector(SwapVM.ETHTransferFailed.selector));
        swapVM.rescueFunds(IERC20(address(0)), amount);
    }

    receive() external payable {}
}
