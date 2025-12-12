// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";

uint256 constant BPS = 1e9;

library FeeArgsBuilder {
    using Calldata for bytes;

    error FeeBpsOutOfRange(uint32 feeBps);
    error FeeMissingFeeBPS();
    error ProtocolFeeMissingFeeBPS();
    error ProtocolFeeMissingTo();
    error ProgressiveFeeMissingFeeBPS();

    function buildFlatFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function buildProtocolFee(uint32 feeBps, address to) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps, to);
    }

    function buildProgressiveFee(uint32 feeBps) internal pure returns (bytes memory) {
        require(feeBps <= BPS, FeeBpsOutOfRange(feeBps));
        return abi.encodePacked(feeBps);
    }

    function parseFlatFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, FeeMissingFeeBPS.selector)));
    }

    function parseProtocolFee(bytes calldata args) internal pure returns (uint32 feeBps, address to) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProtocolFeeMissingFeeBPS.selector)));
        to = address(uint160(bytes20(args.slice(4, 24, ProtocolFeeMissingTo.selector))));
    }

    function parseProgressiveFee(bytes calldata args) internal pure returns (uint32 feeBps) {
        feeBps = uint32(bytes4(args.slice(0, 4, ProgressiveFeeMissingFeeBPS.selector)));
    }
}

contract Fee {
    using SafeERC20 for IERC20;
    using ContextLib for Context;

    error FeeShouldBeAppliedBeforeSwapAmountsComputation();

    IAqua private immutable _AQUA;

    constructor(address aqua) {
        _AQUA = IAqua(aqua);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        _feeAmountIn(ctx, feeBps);
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    function _flatFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseFlatFee(args);
        _feeAmountOut(ctx, feeBps);
    }

    /// @param args.feeBps | 4 bytes (base fee in bps, 1e9 = 100%)
    function _progressiveFeeInXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseProgressiveFee(args);

        if (ctx.query.isExactIn) {
            // Increase amountIn by fee only during swap-instruction
            // Formula: dx_eff = dx / (1 + λ * dx / x)
            // Rearranged for precision: dx_eff = (dx * BPS * x) / (BPS * x + λ * dx)
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            ctx.swap.amountIn = (
                (BPS * ctx.swap.amountIn * ctx.swap.balanceIn) /
                (BPS * ctx.swap.balanceIn + feeBps * ctx.swap.amountIn)
            );
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            ctx.runLoop();

            // Increase amountIn by fee after swap-instruction
            // Formula: dx = dx_eff / (1 - λ * dx_eff / x)
            // Rearranged for precision: dx = (dx_eff * BPS * x) / (BPS * x - λ * dx_eff)
            ctx.swap.amountIn = Math.ceilDiv(
                (BPS * ctx.swap.amountIn * ctx.swap.balanceIn),
                (BPS * ctx.swap.balanceIn - feeBps * ctx.swap.amountIn)
            );
        }
    }

    /// @param args.feeBps | 4 bytes (base fee in bps, 1e9 = 100%)
    function _progressiveFeeOutXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeBps = FeeArgsBuilder.parseProgressiveFee(args);

        if (ctx.query.isExactIn) {
            ctx.runLoop();

            // Decrease amountOut by fee after swap-instruction
            // Formula: dy_eff = dy / (1 + λ * dy / y)
            // Rearranged for precision: dy_eff = (dy * BPS * y) / (BPS * y + λ * dy)
            ctx.swap.amountOut = (
                (BPS * ctx.swap.amountOut * ctx.swap.balanceOut) /
                (BPS * ctx.swap.balanceOut + feeBps * ctx.swap.amountOut)
            );
        } else {
            // Decrease amountOut by fee only during swap-instruction
            // Formula: dy = dy_eff / (1 - λ * dy_eff / y)
            // Rearranged for precision: dy = (dy_eff * BPS * y) / (BPS * y - λ * dy_eff)
            uint256 takerDefinedAmountOut = ctx.swap.amountOut;
            ctx.swap.amountOut = Math.ceilDiv(
                (BPS * ctx.swap.amountOut * ctx.swap.balanceOut),
                (BPS * ctx.swap.balanceOut - feeBps * ctx.swap.amountOut)
            );
            ctx.runLoop();
            ctx.swap.amountOut = takerDefinedAmountOut;
        }
    }

    // текущие проблемы:
    // 1) Нарушается аддитивность при использовании физов на выходе - т.е. если бить своп на части. Причина возникает из-за того что
    // физы берутся из amountOut и курс для следующего свопа становится ЛУЧШЕ чем если бы не было физов
    // Решение 1: эквивалентная формула рассчета feeInBips = f(feeOutBps) (инструкция feeOutAsInXYCXD) - НЕ СРАБОТАЛО,
    // так как f() - есть функция свопа и тогда feeInBips - фактически ведет себя как прогрессивные физы
    // Решение 2: Отказаться от физов на выходе и всегда брать физы на входе - ТАК КАК ФИЗЫ НА ВХОДЕ НЕ НАРУШАЮТ АДДИТИВНОСТЬ
    // Решение 3: перевод SwapVM на механизм без реинвестирования физов - т.е. физы всегда пишутся в сторедж и не реинвестируются в балансы мейкера,
    // но сделать так чтобы часть инструкций позволяли реинвестировать физы с помощью явной инструкции. В регистрах появляется учет физов отдельно от балансов мейкера:
    // новые поля uint256 ctx.swap.feeInCollected; uint256 ctx.swap.feeOutCollected; uint256 ctx.swap.feeIn; uint256 ctx.swap.feeOut;
    // ----------------------
    // 2) Пресижн лосс при компенсации расползания диапазона цен - т.е. если свопить в пуле с концентрированной ликвидностью
    // Решение 1: уменьшение погрешности за счет АБСОЛЮТНЫХ scale в 10 раз от текущего варианта
    // Решение 2: аккаунтинг физов в отдельном сторедже что дает возможность математически корректно реинвестировать физы (не нарущая соотношение dx/X = dy/Y = dL/L)
    // Решение 3: перевод SwapVM на механизм без реинвестирования физов - т.е. физы всегда пишутся в сторедж и не реинвестируются в балансы мейкера,
    // но сделать так чтобы часть инструкций позволяли реинвестировать физы с помощью явной инструкции. В регистрах появляется учет физов отдельно от балансов мейкера:
    // новые поля uint256 ctx.swap.feeInCollected; uint256 ctx.swap.feeOutCollected; uint256 ctx.swap.feeIn; uint256 ctx.swap.feeOut;
    // ----------------------
    // 3) протокольные физы нарушают аккаунтинг мейкера - т.е. физы берутся из amountOut, но баланс мейкера уменьшается на полную сумму amountOut
    // Решение найдено: нужно ставить инструкцию protocolFeeAmountOutXD ДО dynamicBalancesXD
    // ----------------------
    // 4) Проблема с прогрессивными физами - аддитивность (?)
    // Решение 1: изменить подход
    // Решение 2: использовать дикей в блоке или от времени
    // Решение 3: отказаться от них

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _protocolFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountOut = _feeAmountOut(ctx, feeBps);
        // 1) Требуется решить: здесь таже проблема с аддитивностью, но все еще хуже
        // 2) Решено !!!: из выходного amountOut при exactIn вычитаются физы и дальше отправляются протоколу
        // но проблема в том, что дальше в _dynamicBalances
        // balances[ctx.query.orderHash][ctx.query.tokenOut] -= swapAmountOut;
        // значение balances для tokenOut будет уменьшено на величину amountOut из которой
        // вычли физы - как будто бы данные физы осели у мейкера - но так быть не должно,
        // поскольку физически физы уже отправились протоколу
        // в итоге нарушается аккаунтинг
        // это справедливо только для exactIn, для excactOut - все верно

        if (!ctx.vm.isStaticContext) {
            IERC20(ctx.query.tokenOut).safeTransferFrom(ctx.query.maker, to, feeAmountOut);
        }
    }

    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%)
    /// @param args.to     | 20 bytes (address to send pulled tokens to)
    function _aquaProtocolFeeAmountOutXD(Context memory ctx, bytes calldata args) internal {
        (uint256 feeBps, address to) = FeeArgsBuilder.parseProtocolFee(args);
        uint256 feeAmountOut = _feeAmountOut(ctx, feeBps);

        if (!ctx.vm.isStaticContext) {
            _AQUA.pull(ctx.query.maker, ctx.query.orderHash, ctx.query.tokenOut, feeAmountOut, to);
        }
    }

    // Internal functions

    function _feeAmountIn(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountIn) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Decrease amountIn by fee only during swap-instruction
            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            feeAmountIn = ctx.swap.amountIn * feeBps / BPS;
            ctx.swap.amountIn -= feeAmountIn; // amountIn -> уменьшаем на физы
            ctx.runLoop(); // amountOut -> по уменьшенному amountIn
            ctx.swap.amountIn = takerDefinedAmountIn; // восстанавливаем amountIn
            // курс для следующего свопа будет:
            // (balanceOut - amountOut) / (balanceIn + amountIn) <= (balanceOut - amountOut) / (balanceIn + amountIn - feeAmountIn)
            // TODO: что хуже чем было бы без физов - поэтому аддитивность не нарушается !!!
        } else {
            // Increase amountIn by fee after swap-instruction
            ctx.runLoop();
            feeAmountIn = ctx.swap.amountIn * feeBps / (BPS - feeBps);
            ctx.swap.amountIn += feeAmountIn;
            // TODO: курс для следующего свопа будет хуже чем было бы без физов - поэтому аддитивность не нарушается !!!
            // (balanceOut - amountOut) / (balanceIn + amountIn + feeAmountIn) <= (balanceOut - amountOut) / (balanceIn + amountIn)
        }
    }

    function _feeAmountOut(Context memory ctx, uint256 feeBps) internal returns (uint256 feeAmountOut) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        // что здесь по сути происходит - поскольку физы "реинвестируются" в балансы мейкера на выходном токене
        // курс для следующего свопа будет в туже сторону ЛУЧШЕ для следующего свопа - отсюда нарушается аддитивность
        if (ctx.query.isExactIn) {
            // Decrease amountOut by fee after passing to swap-instruction
            ctx.runLoop(); // amountIn -> amountOut

            feeAmountOut = ctx.swap.amountOut * feeBps / BPS;
            // здесь мы честно берем физы в tokenOut
            ctx.swap.amountOut -= feeAmountOut; // amountOut -> уменьшаем на физы
            // курс для следующего свопа будет:
            // (balanceOut - amountOut + feeAmountOut) / (balanceIn + amountIn) >= (balanceOut - amountOut) / (balanceIn + amountIn)
            // TODO: что лучше чем было бы без физов !!!
        } else {
            // Increase amountOut by fee only during swap-instruction
            // причем здесь на самом деле мы берем фактически физы в tokenIn:
            // мы искуственно повышаем amountOut что приводит к тому что повышается tokenIn и по факту все равно возьмем
            // физами в tokenIn (тем токеном с которым пришел taker), просто величина физов соответствует как буд-то бы взяли
            // заданное количество в tokenOut
            uint256 takerDefinedAmountOut = ctx.swap.amountOut;
            feeAmountOut = ctx.swap.amountOut * feeBps / (BPS - feeBps);
            ctx.swap.amountOut += feeAmountOut;
            ctx.runLoop();

            ctx.swap.amountOut = takerDefinedAmountOut;
            // TODO: что курс для следующего свопа будет лучше чем было бы без физов
            // (balanceOut - amountOut) / (balanceIn + amountIn) >= (balanceOut - amountOut - feeAmountOut) / (balanceIn + amountIn)
        }
    }

    /// @notice Fee on output converted to equivalent fee on input for XYC formula
    /// @dev This preserves additivity by taking fee from input instead of output
    /// @dev Works for both regular XYC and concentrated liquidity (same formula with virtual balances)
    /// @dev Formula derivation: For taker to receive same amountOut with feeIn as with feeOut:
    ///      (y * dx) / (x + dx) * (1 - λ) = (y * dx * (1 - μ)) / (x + dx * (1 - μ))
    ///      Solving for μ: μ = λ * (x + dx) / (x + dx * λ)
    /// @param args.feeBps | 4 bytes (fee in bps, 1e9 = 100%, expressed as feeOut percentage)
    function _feeOutAsInXYCXD(Context memory ctx, bytes calldata args) internal {
        uint256 feeOutBps = FeeArgsBuilder.parseFlatFee(args);
        _feeOutAsInXYC(ctx, feeOutBps);
    }

    /// @notice Internal implementation of feeOut→feeIn conversion for XYC formula
    /// @param ctx The swap context
    /// @param feeOutBps The fee percentage expressed as output fee (what would be taken from output)
    function _feeOutAsInXYC(Context memory ctx, uint256 feeOutBps) internal returns (uint256 feeAmountIn) {
        require(ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, FeeShouldBeAppliedBeforeSwapAmountsComputation());

        if (ctx.query.isExactIn) {
            // Convert feeOut to equivalent feeIn for XYC (exactIn case)
            // Derivation: For taker to receive same amountOut with feeIn as with feeOut:
            //   (y * dx) / (x + dx) * (1 - λ) = (y * dx * (1 - μ)) / (x + dx * (1 - μ))
            // Solving for μ: μ = λ * (x + dx) / (x + dx * λ)
            // тоже нарушает аддитивность поскольку зависит от amountIn - это значит что если бить сумму,
            // то тогда процент физов зависит от входа - чем больше вход, тем больше физов в процентах соберем
            uint256 feeInBps = feeOutBps * (ctx.swap.balanceIn + ctx.swap.amountIn) * BPS
                / ((ctx.swap.balanceIn * BPS) + (ctx.swap.amountIn * feeOutBps));

            uint256 takerDefinedAmountIn = ctx.swap.amountIn;
            feeAmountIn = ctx.swap.amountIn * feeInBps / BPS;
            ctx.swap.amountIn -= feeAmountIn;
            ctx.runLoop();
            ctx.swap.amountIn = takerDefinedAmountIn;
        } else {
            // For exactOut: first compute swap with original amountOut, then add fee to amountIn
            // Derivation: feeAmount = amountIn_raw * λ * y / ((1-λ)*y - dy)
            // Which equals: amountIn_raw * μ / (BPS - μ) where μ = λ * y / (y - dy)
            ctx.runLoop();

            // Convert feeOut to equivalent feeIn for XYC (exactOut case)
            // μ = λ * y / (y - dy)
            uint256 feeInBps = feeOutBps * ctx.swap.balanceOut
                / (ctx.swap.balanceOut - ctx.swap.amountOut);

            // Add fee to amountIn: feeAmount = amountIn * μ / (BPS - μ)
            feeAmountIn = Math.ceilDiv(ctx.swap.amountIn * feeInBps, BPS - feeInBps);
            ctx.swap.amountIn += feeAmountIn;
        }
    }
}
