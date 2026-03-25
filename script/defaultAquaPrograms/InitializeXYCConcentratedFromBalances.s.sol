// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { XYCConcentratePriceSolver } from "../utils/XYCConcentratePriceSolver.sol";
import { InitializeXYCConcentratedBase } from "./InitializeXYCConcentratedBase.s.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

/// @title InitializeXYCConcentratedFromBalances
/// @notice Initialize an XYC Concentrated strategy from fixed balances and one price bound.
///   Computes the opposite bound from (bLt, bGt, priceSpot, known bound).
/// @dev Reads Aqua address from .env (AQUA=0x...).
///   Strategy parameters are passed as env vars:
///
///   ROUTER=0x... \
///   TOKEN_A=0x... \
///   TOKEN_B=0x... \
///   BALANCE_LT=1000000000000000000000 \
///   BALANCE_GT=1000000000000000000000 \
///   PRICE_SPOT=1000000000000000000 \
///   PRICE_MIN=800000000000000000 \
///   FEE_BPS=3000000 \
///   PROTOCOL_FEE_BPS=0 \
///   PROTOCOL_FEE_RECIPIENT=0x0000000000000000000000000000000000000000 \
///   KYC_NFT=0x0000000000000000000000000000000000000000 \
///   forge script script/defaultAquaPrograms/InitializeXYCConcentratedFromBalances.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
/// Prices are in 1e18 fixed-point (P = tokenGt/tokenLt).
/// Set exactly one of PRICE_MIN or PRICE_MAX.
/// The script derives the other from (bLt, bGt, priceSpot).
/// PROTOCOL_FEE_BPS / PROTOCOL_FEE_RECIPIENT - optional protocol fee (skipped if 0).
/// KYC_NFT - optional ERC721 gate; taker must hold >= 1 NFT to swap (skipped if zero address).
contract InitializeXYCConcentratedFromBalances is InitializeXYCConcentratedBase {
    using SafeCast for uint256;

    function run() external {
        address aqua = _readAqua();

        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 balanceLt = vm.envUint("BALANCE_LT");
        uint256 balanceGt = vm.envUint("BALANCE_GT");
        uint256 sqrtPspot = Math.sqrt(vm.envUint("PRICE_SPOT") * 1e18);
        uint32 feeBps = vm.envUint("FEE_BPS").toUint32();
        uint32 protocolFeeBps = uint32(vm.envOr("PROTOCOL_FEE_BPS", uint256(0)));
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", address(0));
        address kycNft = vm.envOr("KYC_NFT", address(0));

        (uint256 sqrtPriceMin, uint256 sqrtPriceMax) = _resolveBounds(balanceLt, balanceGt, sqrtPspot);

        bool aIsLt = tokenA < tokenB;
        uint256 balA = aIsLt ? balanceLt : balanceGt;
        uint256 balB = aIsLt ? balanceGt : balanceLt;

        _initialize(aqua, router, tokenA, tokenB, balA, balB, sqrtPriceMin, sqrtPriceMax, feeBps, protocolFeeBps, protocolFeeRecipient, kycNft);
    }

    function _resolveBounds(
        uint256 bLt,
        uint256 bGt,
        uint256 sqrtPspot
    ) internal view returns (uint256 sqrtPriceMin, uint256 sqrtPriceMax) {
        bool hasMin = vm.envOr("PRICE_MIN", uint256(0)) > 0;
        bool hasMax = vm.envOr("PRICE_MAX", uint256(0)) > 0;
        require(hasMin != hasMax, "Set exactly one of PRICE_MIN or PRICE_MAX");

        if (hasMin) {
            sqrtPriceMin = Math.sqrt(vm.envUint("PRICE_MIN") * 1e18);
            sqrtPriceMax = XYCConcentratePriceSolver.computeSqrtPriceMax(bLt, bGt, sqrtPspot, sqrtPriceMin);
            console2.log("Derived sqrtPriceMax:", sqrtPriceMax);
        } else {
            sqrtPriceMax = Math.sqrt(vm.envUint("PRICE_MAX") * 1e18);
            sqrtPriceMin = XYCConcentratePriceSolver.computeSqrtPriceMin(bLt, bGt, sqrtPspot, sqrtPriceMax);
            console2.log("Derived sqrtPriceMin:", sqrtPriceMin);
        }
    }
}
// solhint-enable no-console
