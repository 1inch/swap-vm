// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { AquaOpcodes } from "../../src/opcodes/AquaOpcodes.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "../../src/instructions/XYCConcentrate.sol";
import { Fee } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../../test/utils/ProgramBuilder.sol";

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
///   FEE_BPS=3000000 \
///   forge script script/e2e/E2EXYCConcentratedUsdcWeth.s.sol \
///     --rpc-url $SEPOLIA_RPC --private-key $PK --broadcast
///
///   ETH_USD_PRICE : current ETH price in USD (integer, e.g. 3000)
///   AMOUNT_USDC   : USDC to seed (raw 6-decimal, e.g. 100e6 = 100 USDC)
///   AMOUNT_WETH   : WETH to seed (raw 18-decimal, e.g. 5e16 = 0.05 ETH)
///   SWAP_AMOUNT_IN: USDC to swap as taker (raw, e.g. 1e6 = 1 USDC)
///   FEE_BPS       : fee in 1e9 basis (3000000 = 0.3%). Optional, default 0.3%
///   RANGE_PCT     : price range ±% (default 20 → ±20%)
contract E2EXYCConcentratedUsdcWeth is Script, AquaOpcodes {
    using ProgramBuilder for Program;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    constructor() AquaOpcodes(address(1)) {}

    function run() external {
        (address aqua, address router) = _readConfig();

        uint256 ethUsdPrice = vm.envUint("ETH_USD_PRICE");
        uint256 amountUsdc = vm.envUint("AMOUNT_USDC");
        uint256 amountWeth = vm.envUint("AMOUNT_WETH");
        uint256 swapAmountIn = vm.envUint("SWAP_AMOUNT_IN");
        uint32 feeBps = vm.envOr("FEE_BPS", uint256(3000000)).toUint32();
        uint256 rangePct = vm.envOr("RANGE_PCT", uint256(20));

        // USDC < WETH by address → Lt = USDC, Gt = WETH
        // P = tokenGt/tokenLt = WETH_raw per USDC_raw
        // For ETH=$3000: 1 USDC_raw (1e-6 USD) buys 1e18/(3000*1e6) WETH_raw ≈ 3.33e8
        uint256 priceFp = Math.mulDiv(1e18, 1e18, ethUsdPrice * 1e6);
        uint256 sqrtPspot = Math.sqrt(priceFp * 1e18);
        uint256 sqrtPmin = Math.sqrt(Math.mulDiv(priceFp, (100 - rangePct), 100) * 1e18);
        uint256 sqrtPmax = Math.sqrt(Math.mulDiv(priceFp, (100 + rangePct), 100) * 1e18);

        console2.log("=== E2E: USDC/WETH Concentrated Liquidity ===");
        console2.log("ETH price:   $", ethUsdPrice);
        console2.log("sqrtPspot:   ", sqrtPspot);
        console2.log("sqrtPmin:    ", sqrtPmin);
        console2.log("sqrtPmax:    ", sqrtPmax);

        // Step 0: Wrap ETH → WETH (Aqua keeps tokens with the maker, no custody transfer)
        vm.startBroadcast();
        IWETH(WETH_SEPOLIA).deposit{ value: amountWeth }();
        vm.stopBroadcast();
        console2.log("Wrapped WETH:", amountWeth);

        // Step 1: Initialize strategy
        ISwapVM.Order memory order = _initializeStrategy(
            aqua, router,
            amountUsdc, amountWeth,
            sqrtPspot, sqrtPmin, sqrtPmax,
            feeBps
        );

        // Step 2: Execute test swap (USDC → WETH)
        _executeSwap(router, order, swapAmountIn);
    }

    function _initializeStrategy(
        address aqua,
        address router,
        uint256 amountUsdc,
        uint256 amountWeth,
        uint256 sqrtPspot,
        uint256 sqrtPmin,
        uint256 sqrtPmax,
        uint32 feeBps
    ) internal returns (ISwapVM.Order memory order) {
        // Lt = USDC, Gt = WETH
        (uint256 targetL, uint256 actualUsdc, uint256 actualWeth) = XYCConcentrateArgsBuilder
            .computeLiquidityFromAmounts(amountUsdc, amountWeth, sqrtPspot, sqrtPmin, sqrtPmax);
        require(targetL > 0, "Zero liquidity");

        console2.log("Liquidity L: ", targetL);
        console2.log("Seeding USDC:", actualUsdc);
        console2.log("Seeding WETH:", actualWeth);

        bytes memory bytecode = _buildProgram(sqrtPmin, sqrtPmax, feeBps);

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: msg.sender,
            useAquaInsteadOfSignature: true,
            shouldUnwrapWeth: false,
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
            program: bytecode
        }));

        address[] memory tokens = new address[](2);
        tokens[0] = USDC_SEPOLIA;
        tokens[1] = WETH_SEPOLIA;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = actualUsdc;
        amounts[1] = actualWeth;

        vm.startBroadcast();

        IERC20(USDC_SEPOLIA).approve(aqua, type(uint256).max);
        IERC20(WETH_SEPOLIA).approve(aqua, type(uint256).max);

        bytes32 strategyHash = IAqua(aqua).ship(
            router,
            abi.encode(order),
            tokens,
            amounts
        );

        vm.stopBroadcast();

        console2.log("Strategy hash:", vm.toString(strategyHash));

        _saveResult(strategyHash, router, aqua, actualUsdc, actualWeth, sqrtPmin, sqrtPmax, feeBps);
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
            order,
            USDC_SEPOLIA,
            WETH_SEPOLIA,
            amountIn,
            takerTraitsAndData
        );

        vm.stopBroadcast();

        console2.log("Amount in  (USDC):", swappedIn);
        console2.log("Amount out (WETH):", swappedOut);
    }

    function _buildProgram(
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps
    ) internal pure returns (bytes memory) {
        Program memory program = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            program.build(
                XYCConcentrate._xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPriceMin, sqrtPriceMax)
            ),
            program.build(
                Fee._flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)
            ),
            program.build(XYCSwap._xycSwapXD)
        );
    }

    function _readConfig() internal view returns (address aqua, address router) {
        string memory path = string.concat(vm.projectRoot(), "/config/constants.json");
        string memory json = vm.readFile(path);
        string memory key = string.concat(".", vm.toString(block.chainid));

        aqua = vm.parseJsonAddress(json, string.concat(".aqua", key));
        require(aqua != address(0), "Aqua address not configured");

        router = vm.parseJsonAddress(json, string.concat(".swapVMRouter", key));
        require(router != address(0), "Router address not configured");

        console2.log("Aqua:  ", aqua);
        console2.log("Router:", router);
    }

    function _saveResult(
        bytes32 strategyHash,
        address router,
        address aqua,
        uint256 balanceUsdc,
        uint256 balanceWeth,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps
    ) internal {
        string memory obj = "e2e";
        vm.serializeBytes32(obj, "strategyHash", strategyHash);
        vm.serializeAddress(obj, "router", router);
        vm.serializeAddress(obj, "aqua", aqua);
        vm.serializeAddress(obj, "usdc", USDC_SEPOLIA);
        vm.serializeAddress(obj, "weth", WETH_SEPOLIA);
        vm.serializeUint(obj, "balanceUsdc", balanceUsdc);
        vm.serializeUint(obj, "balanceWeth", balanceWeth);
        vm.serializeUint(obj, "sqrtPriceMin", sqrtPriceMin);
        vm.serializeUint(obj, "sqrtPriceMax", sqrtPriceMax);
        string memory json = vm.serializeUint(obj, "feeBps", uint256(feeBps));

        string memory dir = string.concat("deployments/e2e/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory filePath = string.concat(dir, "/", vm.toString(strategyHash), ".json");
        vm.writeJson(json, filePath);
        console2.log("Result saved:", filePath);
    }
}
// solhint-enable no-console
