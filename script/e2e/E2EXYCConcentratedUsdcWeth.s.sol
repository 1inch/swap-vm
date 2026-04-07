// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";

import { InitializeXYCConcentratedBase } from "../defaultAquaPrograms/InitializeXYCConcentratedBase.s.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

/// @title E2EXYCConcentratedUsdcWeth
/// @notice End-to-end: initialize a USDC/WETH concentrated liquidity strategy
///   on Sepolia and execute a test swap.
/// @dev Usage:
///
///   ETH_USD_PRICE=3000 \
///   AMOUNT_USDC=100000000 \
///   AMOUNT_WETH=50000000000000000 \
///   SWAP_AMOUNT_IN=1000000 \
///   forge script script/e2e/E2EXYCConcentratedUsdcWeth.s.sol \
///     --rpc-url $SEPOLIA_RPC --private-key $PK --broadcast
contract E2EXYCConcentratedUsdcWeth is InitializeXYCConcentratedBase {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    struct E2EParams {
        address aqua;
        address router;
        uint256 ethUsdPrice;
        uint256 amountUsdc;
        uint256 amountWeth;
        uint256 swapAmountIn;
        uint32 feeBps;
        uint256 rangePct;
        uint32 protocolFeeBps;
        address protocolFeeRecipient;
        address kycNft;
    }

    function run() external {
        E2EParams memory p;
        p.aqua = _readAqua();
        p.router = vm.envAddress("ROUTER");
        p.ethUsdPrice = vm.envUint("ETH_USD_PRICE");
        p.amountUsdc = vm.envUint("AMOUNT_USDC");
        p.amountWeth = vm.envUint("AMOUNT_WETH");
        p.swapAmountIn = vm.envUint("SWAP_AMOUNT_IN");
        p.feeBps = vm.envOr("FEE_BPS", uint256(3000000)).toUint32();
        p.rangePct = vm.envOr("RANGE_PCT", uint256(20));
        p.protocolFeeBps = uint32(vm.envUint("PROTOCOL_FEE_BPS"));
        p.protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        p.kycNft = vm.envAddress("KYC_NFT");

        ISwapVM.Order memory order = _initStrategy(p);
        _executeSwap(p.router, order, p.swapAmountIn);
    }

    function _initStrategy(E2EParams memory p) internal returns (ISwapVM.Order memory order) {
        uint256 priceFp = Math.mulDiv(1e18, 1e18, p.ethUsdPrice * 1e6);
        uint256 sqrtPspot = Math.sqrt(priceFp * 1e18);
        uint256 sqrtPmin = Math.sqrt(Math.mulDiv(priceFp, (100 - p.rangePct), 100) * 1e18);
        uint256 sqrtPmax = Math.sqrt(Math.mulDiv(priceFp, (100 + p.rangePct), 100) * 1e18);

        console2.log("=== E2E: USDC/WETH Concentrated Liquidity ===");
        console2.log("ETH price:   $", p.ethUsdPrice);
        console2.log("sqrtPspot:   ", sqrtPspot);
        console2.log("sqrtPmin:    ", sqrtPmin);
        console2.log("sqrtPmax:    ", sqrtPmax);

        (uint256 targetL, uint256 actualUsdc, uint256 actualWeth) = XYCConcentrateArgsBuilder
            .computeLiquidityFromAmounts(p.amountUsdc, p.amountWeth, sqrtPspot, sqrtPmin, sqrtPmax);
        require(targetL > 0, "Zero liquidity");

        console2.log("Liquidity L: ", targetL);
        console2.log("Seeding USDC:", actualUsdc);
        console2.log("Seeding WETH:", actualWeth);

        vm.startBroadcast();
        IWETH(WETH_SEPOLIA).deposit{ value: actualWeth }();
        vm.stopBroadcast();

        bytes memory bytecode = _buildDefaultAquaProgram(
            sqrtPmin, sqrtPmax, p.feeBps, p.protocolFeeBps, p.protocolFeeRecipient, p.kycNft
        );
        _logCommonParams(p.feeBps, p.protocolFeeBps, p.protocolFeeRecipient, p.kycNft);

        bytes32 strategyHash;
        (strategyHash, order) = _shipStrategy(p.aqua, p.router, USDC_SEPOLIA, WETH_SEPOLIA, actualUsdc, actualWeth, bytecode);
        _saveDeployment(strategyHash, p.router, p.aqua, USDC_SEPOLIA, WETH_SEPOLIA, actualUsdc, actualWeth, "");
    }

    function _executeSwap(
        address router,
        ISwapVM.Order memory order,
        uint256 amountIn
    ) internal {
        console2.log("");
        console2.log("=== Test Swap: USDC -> WETH ===");
        console2.log("Swap amount USDC:", amountIn);

        bytes memory takerTraitsAndData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));

        vm.startBroadcast();
        IERC20(USDC_SEPOLIA).approve(router, amountIn);
        (uint256 swappedIn, uint256 swappedOut,) = ISwapVM(router).swap(
            order, USDC_SEPOLIA, WETH_SEPOLIA, amountIn, takerTraitsAndData
        );
        vm.stopBroadcast();

        console2.log("Amount in  (USDC):", swappedIn);
        console2.log("Amount out (WETH):", swappedOut);
    }
}
// solhint-enable no-console
