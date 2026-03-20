// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { Config } from "./utils/Config.sol";
import { XYCConcentratePriceSolver } from "./utils/XYCConcentratePriceSolver.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { XYCConcentrateArgsBuilder } from "../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../src/instructions/Fee.sol";
import { AquaOpcodes } from "../src/opcodes/AquaOpcodes.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "../src/instructions/XYCConcentrate.sol";
import { Fee } from "../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../test/utils/ProgramBuilder.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

/// @title DeployXYCConcentratedFromBalances
/// @notice Deploy an XYC Concentrated strategy from fixed balances and one price bound.
///   Computes the opposite bound from (bLt, bGt, sqrtPspot, known bound).
/// @dev Reads Aqua address from config/constants.json (by chain ID).
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
///   forge script script/DeployXYCConcentratedFromBalances.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
///   Prices are in 1e18 fixed-point (P = tokenGt/tokenLt).
///   Set exactly one of PRICE_MIN or PRICE_MAX.
///   The script derives the other from (bLt, bGt, priceSpot).
contract DeployXYCConcentratedFromBalances is Script, AquaOpcodes {
    using Config for *;
    using ProgramBuilder for Program;
    using SafeCast for uint256;

    constructor() AquaOpcodes(address(1)) {}

    function run() external {
        (address aqua,,,,) = vm.readSwapVMRouterParameters();

        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 balanceLt = vm.envUint("BALANCE_LT");
        uint256 balanceGt = vm.envUint("BALANCE_GT");
        uint256 sqrtPspot = Math.sqrt(vm.envUint("PRICE_SPOT") * 1e18);
        uint32 feeBps = vm.envUint("FEE_BPS").toUint32();

        (uint256 sqrtPriceMin, uint256 sqrtPriceMax) = _resolveBounds(balanceLt, balanceGt, sqrtPspot);

        _deploy(aqua, router, tokenA, tokenB, balanceLt, balanceGt, sqrtPriceMin, sqrtPriceMax, feeBps);
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

    function _deploy(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 balanceLt,
        uint256 balanceGt,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps
    ) internal {
        require(tokenA != tokenB, "Tokens must differ");
        require(sqrtPriceMin < sqrtPriceMax, "sqrtPriceMin must be < sqrtPriceMax");

        bool aIsLt = tokenA < tokenB;
        uint256 balA = aIsLt ? balanceLt : balanceGt;
        uint256 balB = aIsLt ? balanceGt : balanceLt;

        bytes memory bytecode = _buildProgram(sqrtPriceMin, sqrtPriceMax, feeBps);

        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = balA;
        amounts[1] = balB;

        console2.log("=== XYC Concentrated (from balances) ===");
        console2.log("Router:       ", router);
        console2.log("Aqua:         ", aqua);
        console2.log("Token A:      ", tokenA, " balance:", balA);
        console2.log("Token B:      ", tokenB, " balance:", balB);
        console2.log("sqrtPriceMin: ", sqrtPriceMin);
        console2.log("sqrtPriceMax: ", sqrtPriceMax);
        console2.log("Fee (1e9 bps):", uint256(feeBps));

        vm.startBroadcast();

        IERC20(tokenA).approve(aqua, type(uint256).max);
        IERC20(tokenB).approve(aqua, type(uint256).max);

        bytes32 strategyHash = IAqua(aqua).ship(
            router,
            abi.encode(order),
            tokens,
            amounts
        );

        vm.stopBroadcast();

        console2.log("Strategy hash:", vm.toString(strategyHash));
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
}
// solhint-enable no-console
