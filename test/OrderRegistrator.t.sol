// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../src/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { OrderRegistrator } from "../src/extensions/OrderRegistrator.sol";
import { ERC1271MakerMock } from "./mocks/ERC1271MakerMock.sol";

contract OrderRegistratorTest is Test {
    uint256 private constant _MAKER_PRIVATE_KEY = 0x1234;
    uint256 private constant _ANNOUNCED_AT = 1_234_567;

    Aqua public aqua;
    LimitSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    address public maker;

    function setUp() public {
        aqua = new Aqua();
        swapVM = new LimitSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        maker = vm.addr(_MAKER_PRIVATE_KEY);
    }

    function test_AnnouncedAtDefaultsToZero() public view {
        assertEq(swapVM.announcedAt(bytes32(uint256(1))), 0);
    }

    function test_RegisterSignedOrder() public {
        ISwapVM.Order memory order = _buildOrder(maker, false);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _sign(orderHash);
        vm.warp(_ANNOUNCED_AT);

        vm.expectEmit(false, false, false, true, address(swapVM));
        emit OrderRegistrator.OrderRegistered(order, signature);

        swapVM.registerOrder(order, signature);

        assertEq(swapVM.announcedAt(orderHash), _ANNOUNCED_AT);
    }

    function test_RegisterSignedOrderWithERC1271Signature() public {
        address contractMaker = address(new ERC1271MakerMock());
        ISwapVM.Order memory order = _buildOrder(contractMaker, false);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = hex"deadbeef";
        vm.warp(_ANNOUNCED_AT);

        swapVM.registerOrder(order, signature);

        assertEq(swapVM.announcedAt(orderHash), _ANNOUNCED_AT);
    }

    function test_RevertIfSignatureIsInvalid() public {
        ISwapVM.Order memory order = _buildOrder(maker, false);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = hex"deadbeef";

        vm.expectRevert(abi.encodeWithSelector(
            OrderRegistrator.BadSignature.selector,
            maker,
            orderHash,
            signature
        ));
        swapVM.registerOrder(order, signature);

        assertEq(swapVM.announcedAt(orderHash), 0);
    }

    function test_RevertIfOrderIsAlreadyRegistered() public {
        ISwapVM.Order memory order = _buildOrder(maker, false);
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _sign(orderHash);
        swapVM.registerOrder(order, signature);

        vm.expectRevert(abi.encodeWithSelector(OrderRegistrator.OrderAlreadyRegistered.selector, orderHash));
        swapVM.registerOrder(order, signature);
    }

    function test_RegisterActiveAquaOrder() public {
        ISwapVM.Order memory order = _buildOrder(maker, true);
        bytes32 orderHash = swapVM.hash(order);
        _ship(order);
        vm.warp(_ANNOUNCED_AT);

        vm.expectEmit(false, false, false, true, address(swapVM));
        emit OrderRegistrator.OrderRegistered(order, "");

        swapVM.registerOrder(order, "");

        assertEq(swapVM.announcedAt(orderHash), _ANNOUNCED_AT);
    }

    function test_RevertIfAquaOrderIsNotActive() public {
        ISwapVM.Order memory order = _buildOrder(maker, true);
        bytes32 orderHash = swapVM.hash(order);

        vm.expectRevert(abi.encodeWithSelector(
            IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
            maker,
            address(swapVM),
            orderHash,
            address(tokenA)
        ));
        swapVM.registerOrder(order, "");

        assertEq(swapVM.announcedAt(orderHash), 0);
    }

    function _buildOrder(address orderMaker, bool useAqua) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: orderMaker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: useAqua,
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
            program: ""
        }));
    }

    function _sign(bytes32 orderHash) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_MAKER_PRIVATE_KEY, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _ship(ISwapVM.Order memory order) private {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint256[] memory amounts = new uint256[](2);

        vm.prank(maker);
        assertEq(aqua.ship(address(swapVM), abi.encode(order), tokens, amounts), swapVM.hash(order));
    }
}
