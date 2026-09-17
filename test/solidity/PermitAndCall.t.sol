// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { IPermit2 } from "@1inch/solidity-utils/contracts/interfaces/IPermit2.sol";

import { ISwapVM } from "../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../../contracts/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../contracts/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../contracts/opcodes/OpcodesDebug.sol";
import { StaticBalances } from "../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../contracts/instructions/LimitSwap.sol";

import { ERC20PermitMock } from "./mocks/ERC20PermitMock.sol";
import { Permit2TestLib } from "./helpers/Permit2TestLib.sol";

contract PermitAndCallTest is Test, OpcodesDebug {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 private constant PERMIT_SINGLE_TYPEHASH =
        keccak256(
            "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)"
            "PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
        );

    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 private constant MAKER_PRIVATE_KEY = 0x1234;
    uint256 private constant TAKER_PRIVATE_KEY = 0x5678;
    uint256 private constant AMOUNT_IN = 50e18;
    uint256 private constant AMOUNT_OUT = 25e18;

    SwapVMRouter private swapVM;
    ERC20PermitMock private tokenA;
    ERC20PermitMock private tokenB;
    address private maker;
    address private taker;

    function setUp() public {
        maker = vm.addr(MAKER_PRIVATE_KEY);
        taker = vm.addr(TAKER_PRIVATE_KEY);
        swapVM = new SwapVMRouter(address(0), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new ERC20PermitMock("Token A", "TKA");
        tokenB = new ERC20PermitMock("Token B", "TKB");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
    }

    function test_PermitAndCall_EIP2612PermitExecutesSwap() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _buildSwap();
        bytes memory permit = _eip2612Permit(AMOUNT_IN, block.timestamp + 1);
        bytes memory action = abi.encodeCall(ISwapVM.swap, (order, AMOUNT_IN, takerData));

        assertEq(tokenB.allowance(taker, address(swapVM)), 0);

        vm.prank(taker);
        swapVM.permitAndCall(permit, action);

        assertEq(tokenB.allowance(taker, address(swapVM)), 0);
        assertEq(tokenB.nonces(taker), 1);
        assertEq(tokenB.balanceOf(taker), 950e18);
        assertEq(tokenA.balanceOf(taker), AMOUNT_OUT);
        assertEq(tokenB.balanceOf(maker), AMOUNT_IN);
        assertEq(tokenA.balanceOf(maker), 1000e18 - AMOUNT_OUT);
    }

    function test_PermitAndCall_Permit2PermitExecutesSwap() public {
        Permit2TestLib.install();
        vm.prank(taker);
        tokenB.approve(PERMIT2, type(uint256).max);

        (ISwapVM.Order memory order, bytes memory takerData) = _buildSwap(true);
        bytes memory permit = _permit2Permit(
            uint160(AMOUNT_IN),
            uint48(block.timestamp + 1),
            block.timestamp + 1
        );
        bytes memory action = abi.encodeCall(ISwapVM.swap, (order, AMOUNT_IN, takerData));

        vm.prank(taker);
        swapVM.permitAndCall(permit, action);

        assertEq(Permit2TestLib.allowance(taker, address(tokenB), address(swapVM)).amount, 0);
        assertEq(tokenB.balanceOf(taker), 950e18);
        assertEq(tokenA.balanceOf(taker), AMOUNT_OUT);
        assertEq(tokenB.balanceOf(maker), AMOUNT_IN);
        assertEq(tokenA.balanceOf(maker), 1000e18 - AMOUNT_OUT);
    }

    function test_PermitAndCall_ActionRevertBubblesAndRollsBackPermit() public {
        (ISwapVM.Order memory order,) = _buildSwap();
        bytes memory permit = _eip2612Permit(AMOUNT_IN, block.timestamp + 1);
        bytes memory action = abi.encodeCall(ISwapVM.swap, (order, AMOUNT_IN, bytes("")));

        vm.expectRevert(TakerTraitsLib.TakerTraitsMissingTraits.selector);
        vm.prank(taker);
        swapVM.permitAndCall(permit, action);

        assertEq(tokenB.nonces(taker), 0);
        assertEq(tokenB.allowance(taker, address(swapVM)), 0);
        assertEq(tokenB.balanceOf(taker), 1000e18);
        assertEq(tokenA.balanceOf(taker), 0);
    }

    function _buildSwap() private view returns (ISwapVM.Order memory order, bytes memory takerData) {
        return _buildSwap(false);
    }

    function _buildSwap(bool usePermit2) private view returns (ISwapVM.Order memory order, bytes memory takerData) {
        MakerTraitsLib.Args memory makerArgs;
        makerArgs.maker = maker;
        makerArgs.tokenA = address(tokenA);
        makerArgs.tokenB = address(tokenB);
        makerArgs.program = bytes.concat(
            StaticBalances.build(100e18, 200e18),
            LimitSwap.build(address(tokenB), address(tokenA))
        );
        order = MakerTraitsLib.build(makerArgs);

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PRIVATE_KEY, orderHash);

        TakerTraitsLib.Args memory takerArgs;
        takerArgs.taker = taker;
        takerArgs.isExactIn = true;
        takerArgs.isFirstTransferFromTaker = true;
        takerArgs.isAToB = false;
        takerArgs.usePermit2 = usePermit2;
        takerArgs.signature = abi.encodePacked(r, s, v);
        takerData = TakerTraitsLib.build(takerArgs);
    }

    function _eip2612Permit(uint256 amount, uint256 deadline) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, taker, address(swapVM), amount, tokenB.nonces(taker), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tokenB.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TAKER_PRIVATE_KEY, digest);

        return abi.encodePacked(
            address(tokenB),
            abi.encode(taker, address(swapVM), amount, deadline, v, r, s)
        );
    }

    function _permit2Permit(
        uint160 amount,
        uint48 expiration,
        uint256 sigDeadline
    ) private view returns (bytes memory) {
        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: address(tokenB),
                amount: amount,
                expiration: expiration,
                nonce: 0
            }),
            spender: address(swapVM),
            sigDeadline: sigDeadline
        });
        bytes32 detailsHash = keccak256(
            abi.encode(
                PERMIT_DETAILS_TYPEHASH,
                permitSingle.details.token,
                permitSingle.details.amount,
                permitSingle.details.expiration,
                permitSingle.details.nonce
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_SINGLE_TYPEHASH,
                detailsHash,
                permitSingle.spender,
                permitSingle.sigDeadline
            )
        );
        (bool success, bytes memory result) = PERMIT2.staticcall(
            abi.encodeWithSignature("DOMAIN_SEPARATOR()")
        );
        assertTrue(success);
        bytes32 domainSeparator = abi.decode(result, (bytes32));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TAKER_PRIVATE_KEY, digest);
        bytes32 vs = bytes32(uint256(s) | ((uint256(v) - 27) << 255));

        return abi.encodePacked(address(tokenB), abi.encode(taker, permitSingle, abi.encodePacked(r, vs)));
    }
}
