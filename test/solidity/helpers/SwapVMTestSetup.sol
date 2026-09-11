// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";

/// @dev Test ABI of a deployed router. Extra methods live here so tests do not import impls.
interface SwapVMRouter is ISwapVM {
    error UnknownOpcode(uint256 opcode);
    error AquaBalanceInsufficientAfterTakerPush(uint256 balance, uint256 preBalance, uint256 amount);
    error MsgValueInvalidToken();
    error NotEnoughMsgValueAttached();
    error UnexpectedMsgValue();
    error EthTransferFailed();

    event Swapped(
        bytes32 orderHash,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    function asView() external view returns (ISwapVM);

    function balance(bytes32 orderHash, address token) external view returns (uint256);

    function tokenInInvalidators(address maker, bytes32 orderHash, address token) external view returns (uint256);
    function tokenOutInvalidators(address maker, bytes32 orderHash, address token) external view returns (uint256);
    function invalidateBit(uint256 bitIndex) external;
    function invalidateBits(uint256 slot, uint256 mask) external;
    function invalidateTokenIn(bytes32 orderHash, address token) external;

    function registerOrder(Order calldata order, bytes calldata signature) external;
    function announcedAt(bytes32 orderHash) external view returns (uint256);

    function seriesEpoch(address maker, uint256 seriesId) external view returns (uint256);
    function seriesEpochIncrease(uint256 seriesId) external;
    function seriesEpochAdvance(uint256 seriesId, uint8 amount) external;

    function rescueFunds(address token, uint256 amount) external;
}

interface SwapVMRouterDebug is SwapVMRouter {}
interface AquaSwapVMRouter is SwapVMRouter {}
interface LimitSwapVMRouter is SwapVMRouter {}
interface LimitSwapVMRouterDebug is SwapVMRouter {}

/// @dev Test ABI of the deployed traits helper. Tests must not import the impl.
interface TraitsHelper {
    struct MakerTraitsLibArgs {
        address maker;
        address receiver;
        address tokenA;
        address tokenB;
        bool shouldUnwrapWeth;
        bool useAquaInsteadOfSignature;
        bool allowZeroAmountIn;
        bytes program;
    }

    struct TakerTraitsLibArgs {
        address taker;
        bool isExactIn;
        bool shouldUnwrapWeth;
        bool isFirstTransferFromTaker;
        bool useTransferFromAndAquaPush;
        bool isAToB;
        bool allowPartialFill;
        bytes threshold;
        address to;
        bool hasPreTransferInCallback;
        bytes signature;
    }

    function MakerTraitsLibBuild(MakerTraitsLibArgs calldata args) external pure returns (ISwapVM.Order memory);
    function TakerTraitsLibBuild(TakerTraitsLibArgs calldata args) external pure returns (bytes memory);
}

/// @dev Return types: a function named `SwapVMRouter` / `TraitsHelper` shadows the interface.
interface _DeployedSwapVMRouter is SwapVMRouter {}
interface _DeployedSwapVMRouterDebug is SwapVMRouterDebug {}
interface _DeployedAquaSwapVMRouter is AquaSwapVMRouter {}
interface _DeployedLimitSwapVMRouter is LimitSwapVMRouter {}
interface _DeployedLimitSwapVMRouterDebug is LimitSwapVMRouterDebug {}
interface _DeployedTraitsHelper is TraitsHelper {}

/// @dev forge-std `deployCode` analogue: getCode + create. HH3 has no native deployCode.
library DeployCode {
    Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function SwapVMRouter(address aqua, address weth, address owner, string memory name, string memory version) internal returns (_DeployedSwapVMRouter) {
        return _DeployedSwapVMRouter(_deploy("contracts/routers/SwapVMRouter.sol:SwapVMRouter", aqua, weth, owner, name, version));
    }

    function SwapVMRouterDebug(address aqua, address weth, address owner, string memory name, string memory version) internal returns (_DeployedSwapVMRouterDebug) {
        return _DeployedSwapVMRouterDebug(_deploy("contracts/routers/SwapVMRouterDebug.sol:SwapVMRouterDebug", aqua, weth, owner, name, version));
    }

    function AquaSwapVMRouter(address aqua, address weth, address owner, string memory name, string memory version) internal returns (_DeployedAquaSwapVMRouter) {
        return _DeployedAquaSwapVMRouter(_deploy("contracts/routers/AquaSwapVMRouter.sol:AquaSwapVMRouter", aqua, weth, owner, name, version));
    }

    function LimitSwapVMRouter(address aqua, address weth, address owner, string memory name, string memory version) internal returns (_DeployedLimitSwapVMRouter) {
        return _DeployedLimitSwapVMRouter(_deploy("contracts/routers/LimitSwapVMRouter.sol:LimitSwapVMRouter", aqua, weth, owner, name, version));
    }

    function LimitSwapVMRouterDebug(address aqua, address weth, address owner, string memory name, string memory version) internal returns (_DeployedLimitSwapVMRouterDebug) {
        return _DeployedLimitSwapVMRouterDebug(_deploy("contracts/routers/LimitSwapVMRouterDebug.sol:LimitSwapVMRouterDebug", aqua, weth, owner, name, version));
    }

    function BestRouteSelector(address aqua) internal returns (address) {
        return _create("test/solidity/mocks/BestRouteSelector.sol:BestRouteSelector", abi.encode(aqua));
    }

    function TraitsHelper() internal returns (_DeployedTraitsHelper) {
        return _DeployedTraitsHelper(_create("test/solidity/helpers/TraitsHelper.sol:TraitsHelper", ""));
    }

    function _deploy(
        string memory artifact,
        address aqua,
        address weth,
        address owner,
        string memory name,
        string memory version
    ) private returns (address) {
        return _create(artifact, abi.encode(aqua, weth, owner, name, version));
    }

    function _create(string memory artifact, bytes memory args) private returns (address addr) {
        bytes memory bytecode = abi.encodePacked(_VM.getCode(artifact), args);
        assembly ("memory-safe") {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "DeployCode: create failed");
    }
}
