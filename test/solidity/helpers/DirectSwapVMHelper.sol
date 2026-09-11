// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { SwapVMRouter, DeployCode, TraitsHelper } from "./SwapVMTestSetup.sol";
import { StaticBalances, DynamicBalances } from "../../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../../contracts/instructions/LimitSwap.sol";
import { Salt } from "../../../contracts/instructions/Controls.sol";

/// @title Helper contract for Direct (signature-based) SwapVM
contract DirectSwapVMHelper {
    SwapVMRouter public router;
    TraitsHelper internal immutable orders;
    Vm internal vmInstance;

    constructor(address aqua, Vm _vm) {
        router = DeployCode.SwapVMRouter(aqua, address(0), address(this), "SwapVM", "1.0.0");
        orders = DeployCode.TraitsHelper();
        vmInstance = _vm;
    }

    function createSignedOrder(
        address maker,
        uint256 makerPrivateKey,
        TokenMock tokenA,
        TokenMock tokenB,
        uint256 balanceA,
        uint256 balanceB
    ) external view returns (ISwapVM.Order memory order, bytes memory signature) {
        bytes memory programBytes = bytes.concat(
            StaticBalances.build(balanceA, balanceB),
            LimitSwap.build(address(tokenB), address(tokenA)),
            Salt.build(uint64(uint256(keccak256(abi.encode(block.timestamp)))))
        );

        order = orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            program: programBytes
        }));

        bytes32 orderHash = router.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vmInstance.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }
}
