// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { InitializeXYCConcentratedBase } from "./InitializeXYCConcentratedBase.s.sol";

/// @title InitializeXYCConcentrated
/// @notice Initialize an XYC Concentrated Liquidity + Flat Fee strategy via Aqua.
///   Accepts token amounts and both price bounds; computes optimal balances internally.
/// @dev Reads Aqua address from config/constants.json (by chain ID).
///   Strategy parameters are passed as env vars:
///
///   ROUTER=0x... \
///   TOKEN_A=0x... \
///   TOKEN_B=0x... \
///   AMOUNT_A=1000000000000000000 \
///   AMOUNT_B=3000000000 \
///   PRICE_MIN=800000000000000000 \
///   PRICE_MAX=1250000000000000000 \
///   PRICE_SPOT=1000000000000000000 \
///   FEE_BPS=3000000 \
///   PROTOCOL_FEE_BPS=0 \
///   PROTOCOL_FEE_RECIPIENT=0x0000000000000000000000000000000000000000 \
///   KYC_NFT=0x0000000000000000000000000000000000000000 \
///   forge script script/amm/InitializeXYCConcentrated.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
/// Prices are in 1e18 fixed-point (P = tokenGt/tokenLt in raw amounts):
///   1e18 = 1.0, 800000000000000000 = 0.8, etc.
///   The script computes sqrtP = sqrt(P * 1e18) internally.
/// PROTOCOL_FEE_BPS / PROTOCOL_FEE_RECIPIENT - optional protocol fee (skipped if 0).
/// KYC_NFT - optional ERC721 gate; taker must hold >= 1 NFT to swap (skipped if zero address).
contract InitializeXYCConcentrated is InitializeXYCConcentratedBase {
    using SafeCast for uint256;

    function run() external {
        address aqua = _readAqua();

        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 amountA = vm.envUint("AMOUNT_A");
        uint256 amountB = vm.envUint("AMOUNT_B");
        uint256 sqrtPriceMin = Math.sqrt(vm.envUint("PRICE_MIN") * 1e18);
        uint256 sqrtPriceMax = Math.sqrt(vm.envUint("PRICE_MAX") * 1e18);
        uint256 sqrtPspot = Math.sqrt(vm.envUint("PRICE_SPOT") * 1e18);
        uint32 feeBps = vm.envUint("FEE_BPS").toUint32();
        uint32 protocolFeeBps = uint32(vm.envOr("PROTOCOL_FEE_BPS", uint256(0)));
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", address(0));
        address kycNft = vm.envOr("KYC_NFT", address(0));

        require(sqrtPspot >= sqrtPriceMin && sqrtPspot <= sqrtPriceMax, "Spot price outside range");

        bool aIsLt = tokenA < tokenB;
        uint256 availableLt = aIsLt ? amountA : amountB;
        uint256 availableGt = aIsLt ? amountB : amountA;

        (uint256 targetL, uint256 actualLt, uint256 actualGt) = XYCConcentrateArgsBuilder
            .computeLiquidityFromAmounts(availableLt, availableGt, sqrtPspot, sqrtPriceMin, sqrtPriceMax);
        require(targetL > 0, "Zero liquidity - check amounts and price bounds");

        uint256 balA = aIsLt ? actualLt : actualGt;
        uint256 balB = aIsLt ? actualGt : actualLt;

        _initialize(aqua, router, tokenA, tokenB, balA, balB, sqrtPriceMin, sqrtPriceMax, feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);
    }
}
