// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { AddressLib, Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { NativeOrderEscrow } from "./NativeOrderEscrow.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";
import { IBaseEscrow } from "./vendor/interfaces/IBaseEscrow.sol";
import { ImmutablesLib } from "./vendor/libraries/ImmutablesLib.sol";
import { Timelocks, TimelocksLib } from "./vendor/libraries/TimelocksLib.sol";
import { ProxyHashLib } from "./vendor/libraries/ProxyHashLib.sol";

/// @title NativeOrderEscrowFactory
/// @notice Deploys per-order NativeOrderEscrow clones that hold a maker's native ETH as WETH so the order
/// can be filled through an unmodified SwapVM router.
/// @dev The implementation is deployed in the constructor and clones are created with CREATE2
/// where salt = hash(IBaseEscrow.Immutables). Depositing ETH here replaces
/// the maker's EIP-712 signature: only the maker may create (funds custody implies order consent), and the
/// clone validates fills via ERC-1271 against the immutables committed in its own address.
///
/// The factory cannot verify program semantics (which token the program actually sells lives inside
/// instruction args): an order whose program does not sell WETH is simply unfillable, and the deposit
/// always remains recoverable through NativeOrderEscrow.cancel.
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrowFactory is RouterOrderHasher {
    using AddressLib for Address;
    using Clones for address;
    using TimelocksLib for Timelocks;
    using ImmutablesLib for IBaseEscrow.Immutables;

    error NativeOrderZeroDeposit();
    error NativeOrderOnlyMakerCanCreate();
    error NativeOrderAquaNotSupported();
    error NativeOrderExplicitReceiverRequired();
    error NativeOrderInvalidTimelocks();

    /// @notice Emitted when a native order escrow is created and funded.
    /// @param escrow The deployed clone acting as `order.maker` of the filled order.
    /// @param filledOrderHash Hash of the patched order (maker = escrow) that takers fill and quote against.
    /// @param immutables The full immutables pack: hash(immutables) is the CREATE2 salt of `escrow`,
    /// and abi.encode(immutables, filledOrder.traits, keccak256(filledOrder.data)) is the ERC-1271
    /// signature takers must supply.
    /// @param filledOrder The patched order to submit to the router (pre-patch order = same order with
    /// maker = immutables.maker).
    event NativeOrderCreated(
        address indexed escrow,
        bytes32 indexed filledOrderHash,
        IBaseEscrow.Immutables immutables,
        ISwapVM.Order filledOrder
    );

    /// @notice SwapVM router orders are validated against and filled through.
    ISwapVM public immutable ROUTER;
    /// @notice Wrapped native token deposits are held in.
    IWETH public immutable WETH;
    /// @notice NativeOrderEscrow implementation all clones delegate to.
    address public immutable ESCROW_IMPLEMENTATION;
    /// @notice Hash of the EIP-1167 proxy bytecode pointing at ESCROW_IMPLEMENTATION.
    bytes32 public immutable PROXY_BYTECODE_HASH;

    constructor(ISwapVM router, IWETH weth, IERC20 accessToken, uint32 rescueDelay) RouterOrderHasher(router) {
        ROUTER = router;
        WETH = weth;
        ESCROW_IMPLEMENTATION = address(new NativeOrderEscrow(router, weth, accessToken, rescueDelay));
        PROXY_BYTECODE_HASH = ProxyHashLib.computeProxyBytecodeHash(ESCROW_IMPLEMENTATION);
    }

    /// @notice Creates and funds a per-order escrow clone for a native ETH sell order.
    /// @dev The order must be passed in its pre-patch form (maker = msg.sender). The clone address commits
    /// to the pre-patch order hash, resolving the CREATE2 circularity: the filled order references the clone
    /// as maker, so its hash cannot be part of the salt.
    /// @param makerOrder The pre-patch order: maker = msg.sender, receiver set to the real recipient,
    /// program selling WETH.
    /// @param timelocks Stage offsets in seconds from creation (SrcCancellation = expiry, must be non-zero;
    /// SrcPublicCancellation = public GC start, must not precede expiry); deployedAt is stamped by the factory.
    /// @return escrow The deployed and funded clone.
    /// @return filledOrderHash Hash of the patched order takers fill.
    /// @return immutables The immutables pack needed for fills (ERC-1271 signature) and cancellations.
    function create(ISwapVM.Order calldata makerOrder, Timelocks timelocks)
        external
        payable
        returns (address escrow, bytes32 filledOrderHash, IBaseEscrow.Immutables memory immutables)
    {
        require(msg.value > 0, NativeOrderZeroDeposit());
        require(makerOrder.maker == msg.sender, NativeOrderOnlyMakerCanCreate());
        // Native ETH orders with Aqua are not wokring(no "approve" for ETH)
        require(!makerOrder.traits.useAquaInsteadOfSignature(), NativeOrderAquaNotSupported());

        timelocks = timelocks.setDeployedAt(block.timestamp);
        uint256 expiry = timelocks.get(TimelocksLib.Stage.SrcCancellation);
        require(
            expiry > block.timestamp && timelocks.get(TimelocksLib.Stage.SrcPublicCancellation) >= expiry,
            NativeOrderInvalidTimelocks()
        );

        bytes32 dataHash = keccak256(makerOrder.data);
        immutables = IBaseEscrow.Immutables({
            // possible to do "orderHash: ROUTER.hash(makerOrder)", but in-place hashing is much cheaper
            orderHash: _hashOrder(msg.sender, makerOrder.traits, dataHash),
            hashlock: bytes32(0),
            maker: Address.wrap(uint160(msg.sender)),
            taker: Address.wrap(0),
            token: Address.wrap(uint160(address(WETH))),
            amount: msg.value,
            safetyDeposit: 0,
            timelocks: timelocks,
            parameters: ""
        });

        escrow = ESCROW_IMPLEMENTATION.cloneDeterministic(immutables.hashMem());
        // `order.maker` is the clone and an unset receiver resolves to it: the bought
        // tokens would be paid to the escrow instead of the real maker.
        require(makerOrder.traits.receiver(escrow) != escrow, NativeOrderExplicitReceiverRequired());
        NativeOrderEscrow(payable(escrow)).depositAndApprove{ value: msg.value }();

        filledOrderHash = _hashOrder(escrow, makerOrder.traits, dataHash);

        emit NativeOrderCreated(
            escrow,
            filledOrderHash,
            immutables,
            ISwapVM.Order({ maker: escrow, traits: makerOrder.traits, data: makerOrder.data })
        );
    }

    /// @notice Computes the deterministic escrow address for the given immutables.
    /// @param immutables The immutables pack the clone would be deployed with.
    /// @return The CREATE2 address of the corresponding escrow clone.
    function addressOfEscrow(IBaseEscrow.Immutables calldata immutables) external view returns (address) {
        return Create2.computeAddress(immutables.hash(), PROXY_BYTECODE_HASH, address(this));
    }
}
