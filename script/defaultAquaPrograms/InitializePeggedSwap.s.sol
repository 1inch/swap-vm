// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { InitializePeggedSwapBase } from "./InitializePeggedSwapBase.s.sol";

/// @title InitializePeggedSwap
/// @notice Initialize a PeggedSwap + Flat Fee strategy via Aqua.
///   Designed for pegged/correlated pairs (USDC/USDT, WETH/stETH, WBTC/cbBTC, etc.).
/// @dev Reads Aqua address from .env (AQUA=0x...).
///   Strategy parameters are passed as env vars:
///
///   ROUTER=0x... \
///   TOKEN_A=0x... \
///   TOKEN_B=0x... \
///   BALANCE_A=1000000000 \
///   BALANCE_B=1000000000000000000000 \
///   LINEAR_WIDTH=800000000000000000000000000 \
///   RATE_LT=1 \
///   RATE_GT=1 \
///   FEE_BPS=1000000 \
///   PROTOCOL_FEE_BPS=0 \
///   PROTOCOL_FEE_RECIPIENT=0x0000000000000000000000000000000000000000 \
///   KYC_NFT=0x0000000000000000000000000000000000000000 \
///   forge script script/defaultAquaPrograms/InitializePeggedSwap.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
/// LINEAR_WIDTH is the A parameter in 1e27 scale:
///   0.8e27 = 800000000000000000000000000 (tight peg, e.g. USDC/USDT)
///   0.3e27 = 300000000000000000000000000 (looser peg)
///   0     = pure square-root curve
///
/// RATE_LT / RATE_GT normalize tokens with different decimals:
///   Equal decimals (18/18):  RATE_LT=1, RATE_GT=1
///   Mixed (6/18), Lt=6dec:   RATE_LT=1000000000000, RATE_GT=1
///
/// x0/y0 (normalization factors) are computed as:
///   x0 = balance_Lt * RATE_LT,  y0 = balance_Gt * RATE_GT
///
/// PROTOCOL_FEE_BPS / PROTOCOL_FEE_RECIPIENT - protocol fee; must be set explicitly (use 0 to skip).
/// KYC_NFT - ERC721 gate; must be set explicitly (use address(0) to skip).
contract InitializePeggedSwap is InitializePeggedSwapBase {
    using SafeCast for uint256;

    function run() external {
        address aqua = _readAqua();

        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 balanceA = vm.envUint("BALANCE_A");
        uint256 balanceB = vm.envUint("BALANCE_B");
        uint256 linearWidth = vm.envUint("LINEAR_WIDTH");
        uint256 rateLt = vm.envUint("RATE_LT");
        uint256 rateGt = vm.envUint("RATE_GT");
        uint32 feeBps = vm.envUint("FEE_BPS").toUint32();
        uint32 protocolFeeBps = uint32(vm.envUint("PROTOCOL_FEE_BPS"));
        address protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address kycNft = vm.envAddress("KYC_NFT");

        bool aIsLt = tokenA < tokenB;
        uint256 balanceLt = aIsLt ? balanceA : balanceB;
        uint256 balanceGt = aIsLt ? balanceB : balanceA;

        uint256 x0 = balanceLt * rateLt;
        uint256 y0 = balanceGt * rateGt;

        require(x0 > 0 && y0 > 0, "Zero normalized balance");

        _initialize(aqua, router, tokenA, tokenB, balanceA, balanceB, x0, y0, linearWidth, rateLt, rateGt, feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);
    }
}
