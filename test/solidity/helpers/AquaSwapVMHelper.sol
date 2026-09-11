// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter, DeployCode, TraitsHelper } from "./SwapVMTestSetup.sol";
import { XYCSwap } from "../../../contracts/instructions/XYCSwap.sol";
import { Salt } from "../../../contracts/instructions/Controls.sol";

/// @title Helper for Aqua orders — deploys AquaSwapVMRouter from artifact
contract AquaSwapVMHelper {
    AquaSwapVMRouter public router;
    TraitsHelper internal immutable orders;

    constructor(address aqua) {
        router = DeployCode.AquaSwapVMRouter(aqua, address(0), address(this), "SwapVM", "1.0.0");
        orders = DeployCode.TraitsHelper();
    }

    function createOrder(
        address maker,
        TokenMock tokenA,
        TokenMock tokenB
    ) external view returns (ISwapVM.Order memory) {
        bytes memory programBytes = bytes.concat(
            XYCSwap.build(),
            Salt.build(uint64(uint256(keccak256(abi.encode(block.timestamp)))))
        );

        return orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            program: programBytes
        }));
    }
}
