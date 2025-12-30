// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@1inch/solidity-utils/contracts/libraries/ECDSA.sol";
import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { TransientLock, TransientLockLib } from "@1inch/solidity-utils/contracts/libraries/TransientLock.sol";
import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";

import { ISwapVM } from "./interfaces/ISwapVM.sol";
import { IMakerHooks } from "./interfaces/IMakerHooks.sol";
import { ITakerCallbacks } from "./interfaces/ITakerCallbacks.sol";
import { Context, ContextLib, VM, SwapRegisters, SwapQuery  } from "./libs/VM.sol";
import { MakerTraits, MakerTraitsLib } from "./libs/MakerTraits.sol";
import { TakerTraits, TakerTraitsLib } from "./libs/TakerTraits.sol";

abstract contract SwapVM is EIP712 {
    using ECDSA for address;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using Calldata for bytes;
    using TransientLockLib for TransientLock;
    using ContextLib for Context;
    using MakerTraitsLib for MakerTraits;
    using TakerTraitsLib for TakerTraits;

    error BadSignature(address maker, bytes32 orderHash, bytes signature);
    error AquaBalanceInsufficientAfterTakerPush(uint256 balance, uint256 preBalance, uint256 amount);
    error MakerTraitsUnwrapIsIncompatibleWithAqua();
    error MakerTraitsCustomReceiverIsIncompatibleWithAqua();

    event Swapped(
        bytes32 orderHash,
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order("
            "address maker,"
            "uint256 traits,"
            "bytes data"
        ")"
    );

    IAqua public immutable AQUA;

    mapping(bytes32 orderHash => TransientLock) private _reentrancyGuards;

    constructor(address aqua, string memory name, string memory version) EIP712(name, version) {
        AQUA = IAqua(aqua);
    }

    function asView() external view returns (ISwapVM) {
        return ISwapVM(address(this));
    }

    function hash(ISwapVM.Order calldata order) public view returns (bytes32) {
        if (order.traits.useAquaInsteadOfSignature()) {
            return keccak256(abi.encode(order));
        }

        return _hashTypedDataV4(keccak256(abi.encode(
            ORDER_TYPEHASH,
            order.maker,
            order.traits,
            keccak256(order.data)
        )));
    }

    /// @dev Method can be executed in a static-call
    function quote(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash) {
        orderHash = hash(order);

        (TakerTraits takerTraits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        bool isExactIn = takerTraits.isExactIn();
        Context memory ctx = Context({
            vm: VM({
                isStaticContext: true,
                nextPC: 0,
                programPtr: CalldataPtrLib.from(order.traits.program(order.data)),
                takerArgsPtr: CalldataPtrLib.from(takerTraits.instructionsArgs(takerData)),
                opcodes: _instructions()
            }),
            query: SwapQuery({
                orderHash: orderHash,
                maker: order.maker,
                taker: msg.sender,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                isExactIn: isExactIn
            }),
            swap: SwapRegisters({
                balanceIn: 0,
                balanceOut: 0,
                amountIn: isExactIn ? amount : 0,
                amountOut: isExactIn ? 0 : amount
            })
        });

        if (order.traits.useAquaInsteadOfSignature()) {
            (ctx.swap.balanceIn, ctx.swap.balanceOut) = AQUA.safeBalances(order.maker, address(this), orderHash, tokenIn, tokenOut);
        }

        (amountIn, amountOut) = ctx.runLoop();
        order.traits.validate(tokenIn, tokenOut, amountIn);
        takerTraits.validate(takerData, amount, amountIn, amountOut);
    }

    function swap(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash) {
        orderHash = hash(order);
        _reentrancyGuards[orderHash].lock();

        (TakerTraits takerTraits, bytes calldata takerData) = TakerTraitsLib.parse(takerTraitsAndData);
        bool isExactIn = takerTraits.isExactIn();
        Context memory ctx = Context({
            vm: VM({
                isStaticContext: false,
                nextPC: 0,
                programPtr: CalldataPtrLib.from(order.traits.program(order.data)),
                takerArgsPtr: CalldataPtrLib.from(takerTraits.instructionsArgs(takerData)),
                opcodes: _instructions()
            }),
            query: SwapQuery({
                orderHash: orderHash,
                maker: order.maker,
                taker: msg.sender,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                isExactIn: isExactIn
            }),
            swap: SwapRegisters({
                balanceIn: 0,
                balanceOut: 0,
                amountIn: isExactIn ? amount : 0,
                amountOut: isExactIn ? 0 : amount
            })
        });

        if (order.traits.useAquaInsteadOfSignature()) {
            (ctx.swap.balanceIn, ctx.swap.balanceOut) = AQUA.safeBalances(order.maker, address(this), orderHash, tokenIn, tokenOut);
        } else {
            bytes calldata signature = takerTraits.signature(takerData);
            require(order.maker.recoverOrIsValidSignature(orderHash, signature), BadSignature(order.maker, orderHash, signature));
        }

        uint256 originalAquaBalanceIn = ctx.swap.balanceIn;
        (amountIn, amountOut) = ctx.runLoop();
        order.traits.validate(tokenIn, tokenOut, amountIn);
        takerTraits.validate(takerData, amount, amountIn, amountOut);

        if (takerTraits.isFirstTransferFromTaker()) {
            _transferIn(ctx, order, takerTraits, takerData, originalAquaBalanceIn);
            _transferOut(ctx, order, takerTraits, takerData);
        } else {
            _transferOut(ctx, order, takerTraits, takerData);
            _transferIn(ctx, order, takerTraits, takerData, originalAquaBalanceIn);
        }

        _reentrancyGuards[orderHash].unlock();
        emit Swapped(orderHash, order.maker, msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _transferIn(Context memory ctx, ISwapVM.Order calldata order, TakerTraits takerTraits, bytes calldata takerData, uint256 originalAquaBalanceIn) private {
        if (order.traits.hasPreTransferInHook()) {
            (IMakerHooks target, bytes calldata makerHookData) = order.traits.preTransferInHook(order.maker, order.data);
            bytes calldata takerHookData = takerTraits.preTransferInHookData(takerData);
            target.preTransferIn(order.maker, ctx.query.taker, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.query.orderHash, makerHookData, takerHookData);
        }

        if (takerTraits.hasPreTransferInCallback()) {
            bytes calldata callbackData = takerTraits.preTransferInCallbackData(takerData);
            ITakerCallbacks(ctx.query.taker).preTransferInCallback(order.maker, ctx.query.taker, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.query.orderHash, callbackData);
        }

        if (ctx.swap.amountIn > 0) {
            if (order.traits.useAquaInsteadOfSignature()) {
                require(!order.traits.shouldUnwrapWeth(), MakerTraitsUnwrapIsIncompatibleWithAqua());
                require(order.maker == order.traits.receiver(order.maker), MakerTraitsCustomReceiverIsIncompatibleWithAqua());

                if (takerTraits.useTransferFromAndAquaPush()) {
                    IERC20(ctx.query.tokenIn).safeTransferFrom(ctx.query.taker, address(this), ctx.swap.amountIn);
                    IERC20(ctx.query.tokenIn).forceApprove(address(AQUA), ctx.swap.amountIn);
                    AQUA.push(order.maker, address(this), ctx.query.orderHash, ctx.query.tokenIn, ctx.swap.amountIn);
                } else {
                    (uint256 balanceIn,) = AQUA.rawBalances(order.maker, address(this), ctx.query.orderHash, ctx.query.tokenIn);
                    require(balanceIn >= originalAquaBalanceIn + ctx.swap.amountIn, AquaBalanceInsufficientAfterTakerPush(balanceIn, originalAquaBalanceIn, ctx.swap.amountIn));
                }
            } else {
                _transferFrom(ctx.query.taker, order.traits.receiver(order.maker), ctx.query.tokenIn, ctx.swap.amountIn, ctx.query.orderHash, false, order.traits.shouldUnwrapWeth());
            }
        }

        if (order.traits.hasPostTransferInHook()) {
            (IMakerHooks target, bytes calldata makerHookData) = order.traits.postTransferInHook(order.maker, order.data);
            bytes calldata takerHookData = takerTraits.postTransferInHookData(takerData);
            target.postTransferIn(order.maker, ctx.query.taker, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.query.orderHash, makerHookData, takerHookData);
        }
    }

    function _transferOut(Context memory ctx, ISwapVM.Order calldata order, TakerTraits takerTraits, bytes calldata takerData) private {
        if (order.traits.hasPreTransferOutHook()) {
            (IMakerHooks target, bytes calldata makerHookData) = order.traits.preTransferOutHook(order.maker, order.data);
            bytes calldata takerHookData = takerTraits.preTransferOutHookData(takerData);
            target.preTransferOut(order.maker, ctx.query.taker, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.query.orderHash, makerHookData, takerHookData);
        }

        if (takerTraits.hasPreTransferOutCallback()) {
            bytes calldata callbackData = takerTraits.preTransferOutCallbackData(takerData);
            ITakerCallbacks(ctx.query.taker).preTransferOutCallback(order.maker, ctx.query.taker, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.query.orderHash, callbackData);
        }

        _transferFrom(order.maker, takerTraits.to(takerData, msg.sender), ctx.query.tokenOut, ctx.swap.amountOut, ctx.query.orderHash, order.traits.useAquaInsteadOfSignature(), takerTraits.shouldUnwrapWeth());

        if (order.traits.hasPostTransferOutHook()) {
            (IMakerHooks target, bytes calldata makerHookData) = order.traits.postTransferOutHook(order.maker, order.data);
            bytes calldata takerHookData = takerTraits.postTransferOutHookData(takerData);
            target.postTransferOut(order.maker, ctx.query.taker, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut, ctx.query.orderHash, makerHookData, takerHookData);
        }
    }

    function _transferFrom(address from, address to, address token, uint256 amount, bytes32 orderHash, bool useAqua, bool unwrapWeth) private {
        if (unwrapWeth) {
            _transferOrPull(from, address(this), token, amount, orderHash, useAqua);
            IWETH(token).safeWithdrawTo(amount, to);
        } else {
            _transferOrPull(from, to, token, amount, orderHash, useAqua);
        }
    }

    function _transferOrPull(address from, address to, address token, uint256 amount, bytes32 orderHash, bool useAqua) private {
        if (useAqua) {
            AQUA.pull(from, orderHash, token, amount, to);
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    /// @dev Override this function in router to provide supported instruction list
    function _instructions() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory) { }
}
