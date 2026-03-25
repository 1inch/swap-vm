// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { InitializeXYCSwapBase } from "./InitializeXYCSwapBase.s.sol";

/// @title InitializeXYCSwap
/// @notice Initialize a vanilla XYC (constant product xy=k) + Flat Fee strategy via Aqua.
///   Suitable for any token pair; the simplest AMM curve.
/// @dev Reads Aqua address from .env (AQUA=0x...).
///   Strategy parameters are passed as env vars:
///
///   ROUTER=0x... \
///   TOKEN_A=0x... \
///   TOKEN_B=0x... \
///   BALANCE_A=1000000000000000000 \
///   BALANCE_B=3000000000 \
///   FEE_BPS=3000000 \
///   PROTOCOL_FEE_BPS=0 \
///   PROTOCOL_FEE_RECIPIENT=0x0000000000000000000000000000000000000000 \
///   KYC_NFT=0x0000000000000000000000000000000000000000 \
///   forge script script/defaultAquaPrograms/InitializeXYCSwap.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
/// PROTOCOL_FEE_BPS / PROTOCOL_FEE_RECIPIENT - optional protocol fee (skipped if 0).
/// KYC_NFT - optional ERC721 gate; taker must hold >= 1 NFT to swap (skipped if zero address).
contract InitializeXYCSwap is InitializeXYCSwapBase {
    using SafeCast for uint256;

    function run() external {
        address aqua = _readAqua();

        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 balanceA = vm.envUint("BALANCE_A");
        uint256 balanceB = vm.envUint("BALANCE_B");
        uint32 feeBps = vm.envUint("FEE_BPS").toUint32();
        uint32 protocolFeeBps = uint32(vm.envOr("PROTOCOL_FEE_BPS", uint256(0)));
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", address(0));
        address kycNft = vm.envOr("KYC_NFT", address(0));

        _initialize(aqua, router, tokenA, tokenB, balanceA, balanceB, feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);
    }
}
