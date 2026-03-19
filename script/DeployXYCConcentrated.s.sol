// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { Config } from "./utils/Config.sol";

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

/// @title DeployXYCConcentrated
/// @notice Deploy an XYC Concentrated Liquidity + Flat Fee strategy via Aqua
/// @dev Reads Aqua address from config/constants.json (by chain ID).
///   Strategy parameters are passed as env vars:
///
///   ROUTER=0x... \
///   TOKEN_A=0x... \
///   TOKEN_B=0x... \
///   AMOUNT_A=1000000000000000000 \
///   AMOUNT_B=3000000000 \
///   SQRT_PRICE_MIN=54772255750516611345 \
///   SQRT_PRICE_MAX=59160797830996160425 \
///   SQRT_PRICE_SPOT=54772255750516611345 \
///   FEE_BPS=3000000 \
///   forge script script/DeployXYCConcentrated.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
/// Computing sqrt prices for a token pair (P = tokenGt / tokenLt in raw amounts):
///   sqrtP = sqrt(P * 1e18) in 1e18 fixed-point
///   Example: ETH/USDT where USDT < WETH (addresses), P = WETH_amount/USDT_amount
///     For ETH = $3000: P = 1e18 / 3000e6 = 333333333333
///     sqrtPspot = sqrt(333333333333 * 1e18) = 577350269189625764
contract DeployXYCConcentrated is Script, AquaOpcodes {
    using Config for *;
    using ProgramBuilder for Program;
    using SafeCast for uint256;

    constructor() AquaOpcodes(address(1)) {}

    function run() external {
        (address aqua,,,, ) = vm.readSwapVMRouterParameters();

        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 amountA = vm.envUint("AMOUNT_A");
        uint256 amountB = vm.envUint("AMOUNT_B");
        uint256 sqrtPriceMin = vm.envUint("SQRT_PRICE_MIN");
        uint256 sqrtPriceMax = vm.envUint("SQRT_PRICE_MAX");
        uint256 sqrtPspot = vm.envUint("SQRT_PRICE_SPOT");
        uint32 feeBps = vm.envUint("FEE_BPS").toUint32();

        _deploy(aqua, router, tokenA, tokenB, amountA, amountB, sqrtPriceMin, sqrtPriceMax, sqrtPspot, feeBps);
    }

    function _deploy(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint256 sqrtPspot,
        uint32 feeBps
    ) internal {
        require(tokenA != tokenB, "Tokens must differ");
        require(sqrtPriceMin < sqrtPriceMax, "sqrtPriceMin must be < sqrtPriceMax");
        require(sqrtPspot >= sqrtPriceMin && sqrtPspot <= sqrtPriceMax, "Spot price outside range");

        // Sort tokens: Lt = lower address, Gt = higher address
        bool aIsLt = tokenA < tokenB;
        uint256 availableLt = aIsLt ? amountA : amountB;
        uint256 availableGt = aIsLt ? amountB : amountA;

        // Compute optimal balances from available amounts and price bounds
        (uint256 targetL, uint256 actualLt, uint256 actualGt) = XYCConcentrateArgsBuilder
            .computeLiquidityFromAmounts(availableLt, availableGt, sqrtPspot, sqrtPriceMin, sqrtPriceMax);

        require(targetL > 0, "Zero liquidity - check amounts and price bounds");

        uint256 balA = aIsLt ? actualLt : actualGt;
        uint256 balB = aIsLt ? actualGt : actualLt;

        // Build VM bytecode program: concentrate → flat fee → XYC swap
        bytes memory bytecode = _buildProgram(sqrtPriceMin, sqrtPriceMax, feeBps);

        // Build the order
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

        // Prepare arrays for Aqua.ship()
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = balA;
        amounts[1] = balB;

        console2.log("=== XYC Concentrated Liquidity Strategy ===");
        console2.log("Router:       ", router);
        console2.log("Aqua:         ", aqua);
        console2.log("Token A:      ", tokenA, " balance:", balA);
        console2.log("Token B:      ", tokenB, " balance:", balB);
        console2.log("Liquidity (L):", targetL);
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
