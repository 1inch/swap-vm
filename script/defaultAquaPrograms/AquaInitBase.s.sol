// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { SafeERC20, IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { ControlsArgsBuilder } from "../../src/instructions/Controls.sol";
import { AquaOpcodes } from "../../src/opcodes/AquaOpcodes.sol";
import { Fee } from "../../src/instructions/Fee.sol";
import { Controls } from "../../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "../../test/utils/ProgramBuilder.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

/// @title AquaInitBase
/// @notice Shared Aqua ceremony for all AMM strategy initialization scripts.
/// @dev Handles: order building, approve, ship(), deployment JSON, common env vars.
///   Aqua pre-loads balanceIn/balanceOut via AQUA.safeBalances() before VM execution,
///   so strategies do NOT need _dynamicBalancesXD / _staticBalancesXD instructions.
abstract contract AquaInitBase is Script, AquaOpcodes {
    using ProgramBuilder for Program;

    constructor() AquaOpcodes(address(1)) {}

    function _readAqua() internal view returns (address) {
        return vm.envAddress("AQUA");
    }

    /// @notice Ship a strategy to Aqua and save deployment artifact.
    /// @param aqua Aqua protocol address
    /// @param router SwapVM router address
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @param balA Initial balance of tokenA
    /// @param balB Initial balance of tokenB
    /// @param bytecode Compiled program bytecode
    /// @return strategyHash Unique identifier for the deployed strategy
    function _shipStrategy(
        address aqua,
        address router,
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB,
        bytes memory bytecode
    ) internal returns (bytes32 strategyHash, ISwapVM.Order memory order) {
        require(tokenA != tokenB, "Tokens must differ");

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
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = balA;
        amounts[1] = balB;

        console2.log("Router:       ", router);
        console2.log("Aqua:         ", aqua);
        console2.log("Token A:      ", tokenA, " balance:", balA);
        console2.log("Token B:      ", tokenB, " balance:", balB);

        vm.startBroadcast();

        IERC20(tokenA).approve(aqua, type(uint256).max);
        IERC20(tokenB).approve(aqua, type(uint256).max);

        strategyHash = IAqua(aqua).ship(
            router,
            abi.encode(order),
            tokens,
            amounts
        );

        vm.stopBroadcast();

        console2.log("Strategy hash:", vm.toString(strategyHash));
    }

    /// @notice Serialize common fields and write deployment JSON.
    function _saveDeployment(
        bytes32 strategyHash,
        address router,
        address aqua,
        address tokenA,
        address tokenB,
        uint256 balA,
        uint256 balB,
        string memory extraJson
    ) internal {
        string memory obj = "result";
        vm.serializeBytes32(obj, "strategyHash", strategyHash);
        vm.serializeAddress(obj, "router", router);
        vm.serializeAddress(obj, "aqua", aqua);
        vm.serializeAddress(obj, "tokenA", tokenA);
        vm.serializeAddress(obj, "tokenB", tokenB);
        vm.serializeUint(obj, "balanceA", balA);
        string memory json = vm.serializeUint(obj, "balanceB", balB);

        if (bytes(extraJson).length > 0) {
            json = vm.serializeString(obj, "extra", extraJson);
        }

        string memory dir = string.concat("deployments/amm/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/", vm.toString(strategyHash), ".json");
        vm.writeJson(json, path);
        console2.log("Result saved:", path);
    }

    /// @notice Read common env vars: PROTOCOL_FEE_BPS, PROTOCOL_FEE_RECIPIENT, KYC_NFT.
    /// @dev All three must be explicitly set (use 0 / address(0) when not needed).
    function _readCommonParams() internal view returns (uint32 protocolFeeBps, address protocolFeeRecipient, address kycNft) {
        protocolFeeBps = uint32(vm.envUint("PROTOCOL_FEE_BPS"));
        protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        kycNft = vm.envAddress("KYC_NFT");
    }

    /// @notice Build the common prefix: [kycNft guard] + [protocol fee].
    function _buildPrefix(
        Program memory program,
        uint32 protocolFeeBps,
        address protocolFeeRecipient,
        address kycNft
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            kycNft != address(0)
                ? program.build(Controls._onlyTakerTokenBalanceNonZero, ControlsArgsBuilder.buildTakerTokenBalanceNonZero(kycNft))
                : bytes(""),
            protocolFeeBps > 0
                ? program.build(Fee._aquaProtocolFeeAmountInXD, FeeArgsBuilder.buildProtocolFee(protocolFeeBps, protocolFeeRecipient))
                : bytes("")
        );
    }

    /// @notice Log common optional params.
    function _logCommonParams(uint32 feeBps, uint32 protocolFeeBps, address protocolFeeRecipient, address kycNft) internal pure {
        console2.log("Fee (1e9 bps):", uint256(feeBps));
        if (protocolFeeBps > 0) {
            console2.log("ProtocolFee:  ", uint256(protocolFeeBps), " -> ", protocolFeeRecipient);
        }
        if (kycNft != address(0)) {
            console2.log("KYC NFT gate: ", kycNft);
        }
    }
}
// solhint-enable no-console
