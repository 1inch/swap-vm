// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { Config } from "../utils/Config.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { AquaOpcodes } from "../../src/opcodes/AquaOpcodes.sol";
import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "../../src/instructions/XYCConcentrate.sol";
import { Fee } from "../../src/instructions/Fee.sol";

import { Program, ProgramBuilder } from "../../test/utils/ProgramBuilder.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

/// @title InitializeXYCConcentratedBase
/// @notice Shared logic for XYC Concentrated Liquidity strategy initialization scripts.
abstract contract InitializeXYCConcentratedBase is Script, AquaOpcodes {
    using Config for *;
    using ProgramBuilder for Program;

    constructor() AquaOpcodes(address(1)) {}

    function _readAqua() internal view returns (address aqua) {
        (aqua,,,,) = vm.readSwapVMRouterParameters();
    }

    struct InitResult {
        bytes32 strategyHash;
        address router;
        address aqua;
        address tokenA;
        address tokenB;
        uint256 balanceA;
        uint256 balanceB;
        uint256 sqrtPriceMin;
        uint256 sqrtPriceMax;
        uint32 feeBps;
    }

    function _initialize(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB,
        uint256 sqrtPriceMin,
        uint256 sqrtPriceMax,
        uint32 feeBps
    ) internal returns (InitResult memory result) {
        require(tokenA != tokenB, "Tokens must differ");
        require(sqrtPriceMin < sqrtPriceMax, "sqrtPriceMin must be < sqrtPriceMax");

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

        console2.log("=== XYC Concentrated Liquidity Strategy ===");
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

        result = InitResult({
            strategyHash: strategyHash,
            router: router,
            aqua: aqua,
            tokenA: tokenA,
            tokenB: tokenB,
            balanceA: balA,
            balanceB: balB,
            sqrtPriceMin: sqrtPriceMin,
            sqrtPriceMax: sqrtPriceMax,
            feeBps: feeBps
        });

        _saveResult(result);
    }

    function _saveResult(InitResult memory r) internal {
        string memory obj = "result";
        vm.serializeBytes32(obj, "strategyHash", r.strategyHash);
        vm.serializeAddress(obj, "router", r.router);
        vm.serializeAddress(obj, "aqua", r.aqua);
        vm.serializeAddress(obj, "tokenA", r.tokenA);
        vm.serializeAddress(obj, "tokenB", r.tokenB);
        vm.serializeUint(obj, "balanceA", r.balanceA);
        vm.serializeUint(obj, "balanceB", r.balanceB);
        vm.serializeUint(obj, "sqrtPriceMin", r.sqrtPriceMin);
        vm.serializeUint(obj, "sqrtPriceMax", r.sqrtPriceMax);
        string memory json = vm.serializeUint(obj, "feeBps", uint256(r.feeBps));

        string memory dir = string.concat("deployments/amm/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/", vm.toString(r.strategyHash), ".json");
        vm.writeJson(json, path);
        console2.log("Result saved:", path);
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
