// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ---- SwapVM side ----
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../../src/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { LimitOpcodesDebug } from "../../src/opcodes/LimitOpcodesDebug.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { InvalidatorsArgsBuilder } from "../../src/instructions/Invalidators.sol";
import { PiecewiseLinearScaleArgsBuilder } from "../../src/instructions/PiecewiseLinearScale.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { dynamic } from "../utils/Dynamic.sol";

// ---- Fusion / LOP side (real LimitOrderProtocol + SimpleSettlement amount-getter extension) ----
// SimpleSettlement is pinned to solc 0.8.23 (see test/fusion/FusionSettlementArtifact.sol, which forces
// its compilation as a standalone 0.8.23 unit). This file is 0.8.30, so it must NOT import the type —
// the settlement is deployed by artifact name via vm.deployCode and referenced only by address.
import { LimitOrderProtocol } from "@1inch/limit-order-protocol/LimitOrderProtocol.sol";
import { IOrderMixin } from "@1inch/limit-order-protocol/interfaces/IOrderMixin.sol";
import { MakerTraits } from "@1inch/limit-order-protocol/libraries/MakerTraitsLib.sol";
import { TakerTraits } from "@1inch/limit-order-protocol/libraries/TakerTraitsLib.sol";
import { Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import { WrappedTokenMock } from "@1inch/limit-order-protocol/mocks/WrappedTokenMock.sol";

/// @title  FusionParityBase
/// @notice Differential-test scaffolding that replicates a 1inch Fusion order as an equivalent SwapVM
///         program, then exposes builders for both platforms so a test can fill the *same* economic
///         order on each and compare results. Same shape as {LopParityBase}, for Fusion settlement orders.
///
///         The flow mirrors what a real integrator would do:
///           1. deploy the real LimitOrderProtocol + SimpleSettlement contracts;
///           2. describe an order with a platform-agnostic {OrderSpec};
///           3. translate the spec into a Fusion order (+ maker signature) and into a SwapVM program;
///           4. describe a fill with a platform-agnostic {FillSpec};
///           5. translate the fill into LOP TakerTraits and SwapVM taker data;
///           6. run both and compare (done by the concrete test).
///
/// @dev    Token mapping (same as LopParityBase):
///           makerAsset == tokenB == SwapVM tokenOut (the taker receives it)
///           takerAsset == tokenA == SwapVM tokenIn  (the taker provides it)
///
///         SUPPORTED ORDER TYPE (for now): a single-segment Dutch auction with NO gas bump, NO fees and NO
///         whitelist. {OrderSpec} is the place future Fusion features (gas bump, FeeTaker fees, resolver
///         whitelist, multi-point auctions, permit2, ...) get added; {_swapVmReplicable} is the gate that
///         reports whether a given spec has a SwapVM equivalent — exactly like LopParityBase. The builders
///         deliberately implement only the supported type; broaden them feature-by-feature behind the gate.
///
/// @dev    Fusion vs SwapVM auction maths (they differ; the value-parity test reports the gap, no estimate):
///         Fusion encodes a `rateBump` in `_BASE_POINTS = 1e7` units decaying linearly from `initialRateBump`
///         to 0 across the auction; it scales the *amounts* (taking *= (1e7+bump)/1e7 ceil). SwapVM scales
///         the *reserve* balanceIn by a 24-bit `scale` interpolated linearly in time, so the LimitSwap price
///         balanceIn/balanceOut is also linear in time; anchoring the two scale points to the auction
///         endpoints makes the price lines coincide in exact arithmetic. The residual is representational
///         only (24-bit scale vs 1e7 base + integer rounding).
abstract contract FusionParityBase is Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    /// @notice Fusion `_BASE_POINTS` — the rate-bump denominator (100%).
    uint256 internal constant FUSION_BASE_POINTS = 10_000_000;

    /// @dev SwapVM scale is a 24-bit fraction: multiplier == (scale + 1) / 2**24, so 1.0 == 2**24 - 1.
    uint256 internal constant SCALE_ONE = (1 << 24) - 1;

    /// @notice Description of a maker's Fusion order. For now this models the single supported type — a
    ///         single-segment Dutch auction (no gas bump, no fees, no whitelist) — plus the order modality.
    /// @dev    Add fields here for future Fusion features and gate them in {_swapVmReplicable}; the builders
    ///         currently implement only what's below.
    struct OrderSpec {
        uint256 makingAmount;     // makerAsset (tokenB) the maker offers — taker receives this
        uint256 takingAmount;     // takerAsset (tokenA) wanted at auction FINISH (the base/floor price)
        // ---- Dutch auction (SimpleSettlement amount getter), no gas bump ----
        uint32 auctionStartTime;  // auction start timestamp
        uint24 auctionDuration;   // auction length in seconds
        uint24 initialRateBump;   // initial rate bump in 1e7 units (e.g. 1_000_000 == 10%), decays to 0
        // ---- order modality (MakerTraits) ----
        bool allowPartialFills;   // !NO_PARTIAL_FILLS  ; SwapVM: limitSwap1D vs limitSwapOnlyFull1D
        bool allowMultipleFills;  // ALLOW_MULTIPLE_FILLS ; SwapVM: tokenOut- vs bit-invalidator
    }

    /// @notice Platform-agnostic description of a single taker fill.
    struct FillSpec {
        bool byMakingAmount;      // true  => `amount` is makerAsset out (LOP isMakingAmount / VM exactOut)
                                  // false => `amount` is takerAsset in  (LOP !isMakingAmount / VM exactIn)
        uint256 amount;           // requested fill amount (interpreted per byMakingAmount)
        bool hasThreshold;        // whether a rate-protection threshold is supplied
        uint256 threshold;        // exactOut: max takerAsset in ; exactIn: min makerAsset out
    }

    Aqua public immutable aqua;

    uint256 public constant MAKER_PK = 0xA11CE;
    address public maker;
    address public taker; // = address(this)

    LimitSwapVMRouter public swapVM;
    LimitOrderProtocol public lop;
    IWETH public weth;

    /// @notice The real Fusion settlement contract providing the Dutch-auction amount getter (deployed by
    ///         artifact name; referenced only by address since its 0.8.23 type can't be imported here).
    address public settlement;

    TokenMock public tokenA; // takerAsset / tokenIn
    TokenMock public tokenB; // makerAsset / tokenOut

    address public takerAssetToken;
    address public makerAssetToken;

    /// @dev A fixed, non-zero base timestamp so auction arithmetic has head- and tail-room.
    uint40 internal constant BASE_TS = 1_000_000;

    constructor() LimitOpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public virtual {
        maker = vm.addr(MAKER_PK);
        taker = address(this);

        vm.warp(BASE_TS);

        weth = IWETH(address(new WrappedTokenMock("Wrapped Ether", "WETH")));
        swapVM = new LimitSwapVMRouter(address(aqua), address(weth), address(this), "SwapVM", "1.0.0");
        lop = new LimitOrderProtocol(weth);

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        takerAssetToken = address(tokenA);
        makerAssetToken = address(tokenB);

        // Deploy by artifact name so this 0.8.30 file never imports the 0.8.23 SimpleSettlement type.
        // accessToken is only consulted by the (unused) fee post-interaction; any ERC20 works here.
        settlement = deployCode(
            "SimpleSettlement.sol:SimpleSettlement",
            abi.encode(address(lop), IERC20(address(tokenA)), address(weth), address(this))
        );

        // Maker offers makerAsset (tokenB) and receives takerAsset (tokenA).
        tokenB.mint(maker, type(uint224).max);
        tokenA.mint(maker, type(uint224).max);
        vm.startPrank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(lop), type(uint256).max);
        tokenB.approve(address(lop), type(uint256).max);
        vm.stopPrank();

        // Taker (this contract) provides takerAsset (tokenA) and receives makerAsset (tokenB).
        tokenA.mint(taker, type(uint224).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        tokenA.approve(address(lop), type(uint256).max);
        tokenB.approve(address(lop), type(uint256).max);
    }

    // =============================================================================================
    // Fusion builders
    // =============================================================================================

    function _toAddress(address a) internal pure returns (Address) {
        return Address.wrap(uint256(uint160(a)));
    }

    // MakerTraits bit layout (verified against @1inch/limit-order-protocol MakerTraitsLib).
    uint256 private constant _NO_PARTIAL_FILLS_FLAG = 1 << 255;
    uint256 private constant _ALLOW_MULTIPLE_FILLS_FLAG = 1 << 254;
    uint256 private constant _HAS_EXTENSION_FLAG = 1 << 249;

    /// @notice Pack the MakerTraits for a Fusion `spec`: HAS_EXTENSION is always set (the amount getter is
    ///         carried in the extension), plus the partial/multiple modality flags.
    function _fusionMakerTraits(OrderSpec memory spec) internal pure returns (MakerTraits) {
        uint256 mt = _HAS_EXTENSION_FLAG;
        if (!spec.allowPartialFills) mt |= _NO_PARTIAL_FILLS_FLAG;
        if (spec.allowMultipleFills) mt |= _ALLOW_MULTIPLE_FILLS_FLAG;
        return MakerTraits.wrap(mt);
    }

    /// @notice The getter `extraData` consumed by SimpleSettlement: a no-gas-bump, single-segment
    ///         `AuctionDetails` followed by an all-zero FeeTaker fee/whitelist tail (no fees taken).
    /// @dev    Layout (see SimpleSettlement._getRateBump / AmountGetterWithFee._parseFeeData):
    ///           3 gasBumpEstimate=0  4 gasPriceEstimate=0  4 auctionStartTime  3 auctionDuration
    ///           3 initialRateBump  1 pointsCount=0  2 integratorFee=0  1 integratorShare=0
    ///           2 resolverFee=0  1 whitelistDiscount=0  1 whitelistSize=0
    function _fusionGetterExtraData(OrderSpec memory spec) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes3(0), bytes4(0),
            uint32(spec.auctionStartTime), uint24(spec.auctionDuration), uint24(spec.initialRateBump), uint8(0),
            uint16(0), uint8(0), uint16(0), uint8(0), uint8(0)
        );
    }

    /// @notice Build the LOP extension carrying the SimpleSettlement getter in both the MakingAmountData
    ///         (field 2) and TakingAmountData (field 3) slices. Each field is `getter(20) ++ extraData`.
    function _fusionExtension(OrderSpec memory spec) internal view returns (bytes memory) {
        bytes memory data = abi.encodePacked(settlement, _fusionGetterExtraData(spec));
        uint256 m = data.length;        // cumulative end of field 2 (MakingAmountData)
        uint256 mt = m + data.length;   // cumulative end of fields 3..7 (TakingAmountData onward)
        // 8x uint32 cumulative end offsets; fields 0,1 empty (0); 4..7 collapse onto field 3's end.
        uint256 offsets = (m << 64) | (mt << 96) | (mt << 128) | (mt << 160) | (mt << 192) | (mt << 224);
        return abi.encodePacked(bytes32(offsets), data, data);
    }

    /// @notice Build the real Fusion order for `spec`, its extension, and the maker's compact signature.
    /// @dev    HAS_EXTENSION is set and the salt's low 160 bits are bound to the extension hash, as LOP's
    ///         isValidExtension requires.
    function _fusionOrder(OrderSpec memory spec)
        internal
        view
        returns (IOrderMixin.Order memory order, bytes32 r, bytes32 vs, bytes memory extension)
    {
        extension = _fusionExtension(spec);

        uint256 salt = uint256(keccak256(abi.encode(spec)));
        salt = (salt & ~uint256(type(uint160).max)) | (uint256(keccak256(extension)) & type(uint160).max);

        order = IOrderMixin.Order({
            salt: salt,
            maker: _toAddress(maker),
            receiver: _toAddress(address(0)), // 0 => proceeds to maker; no fee receiver needed (no fees)
            makerAsset: _toAddress(makerAssetToken),
            takerAsset: _toAddress(takerAssetToken),
            makingAmount: spec.makingAmount,
            takingAmount: spec.takingAmount,
            makerTraits: _fusionMakerTraits(spec)
        });

        bytes32 orderHash = lop.hashOrder(order);
        uint8 v;
        bytes32 s;
        (v, r, s) = vm.sign(MAKER_PK, orderHash);
        vs = bytes32(uint256(s) | (uint256(v - 27) << 255)); // EIP-2098 compact signature
    }

    /// @notice A single-segment Dutch-auction order; the caller picks the partial/multiple modality (as in
    ///         LopParityBase._baseSpec). All other advanced features default off.
    function _baseSpec(
        uint256 makingAmount,
        uint256 takingAmount,
        uint32 auctionStartTime,
        uint24 auctionDuration,
        uint24 initialRateBump,
        bool allowPartialFills,
        bool allowMultipleFills
    ) internal pure returns (OrderSpec memory s) {
        s.makingAmount = makingAmount;
        s.takingAmount = takingAmount;
        s.auctionStartTime = auctionStartTime;
        s.auctionDuration = auctionDuration;
        s.initialRateBump = initialRateBump;
        s.allowPartialFills = allowPartialFills;
        s.allowMultipleFills = allowMultipleFills;
    }

    /// @notice Whether the SwapVM replica can reproduce this order. The supported type is a single-segment
    ///         Dutch auction with no gas bump / fees / whitelist; the only modelled SwapVM limit is that the
    ///         auction maps to one PiecewiseLinearScale segment whose duration is a uint16. Extend this gate
    ///         as new OrderSpec features are added.
    function _swapVmReplicable(OrderSpec memory spec) internal pure returns (bool) {
        return spec.auctionDuration <= type(uint16).max;
    }

    uint256 private constant _MAKER_AMOUNT_FLAG = 1 << 255;
    uint256 private constant _ARGS_EXTENSION_LENGTH_OFFSET = 224;

    /// @notice Build LOP TakerTraits from a fill spec, encoding the extension length so fillOrderArgs knows
    ///         how many leading bytes of `args` are the extension.
    function _fusionTakerTraits(FillSpec memory fs, uint256 extensionLength) internal pure returns (TakerTraits) {
        uint256 tt = fs.hasThreshold ? fs.threshold : 0; // low 200 bits hold the threshold
        if (fs.byMakingAmount) tt |= _MAKER_AMOUNT_FLAG;
        tt |= extensionLength << _ARGS_EXTENSION_LENGTH_OFFSET;
        return TakerTraits.wrap(tt);
    }

    // =============================================================================================
    // SwapVM builders
    // =============================================================================================

    /// @notice The PiecewiseLinearScale points anchoring the SwapVM auction to the Fusion auction endpoints:
    ///         scale 1.0 at start, `1e7/(1e7+initialRateBump)` at finish, so balanceIn (and thus the price
    ///         balanceIn/balanceOut) decays linearly from the bumped price to the base price.
    function _vmScales(OrderSpec memory spec)
        internal
        pure
        returns (uint40 timestamp, uint16[] memory durations, uint24[] memory scales)
    {
        timestamp = uint40(spec.auctionStartTime);
        durations = new uint16[](1);
        durations[0] = uint16(spec.auctionDuration);
        scales = new uint24[](2);
        scales[0] = uint24(SCALE_ONE); // 1.0 at start
        uint256 denom = FUSION_BASE_POINTS + spec.initialRateBump;
        uint256 scaleEndPlusOne = ((uint256(1) << 24) * FUSION_BASE_POINTS + denom / 2) / denom;
        scales[1] = uint24(scaleEndPlusOne - 1);
    }

    /// @notice The SwapVM order's `balanceIn` at the current block.timestamp — the staticBalances reserve
    ///         AFTER the piecewise auction scale. A full exact-in fill of an `_limitSwapOnlyFull1D` order must
    ///         pass exactly this as amountIn. Recomputes PiecewiseLinearScale._calcScaleNow for the single
    ///         segment, then `balanceIn0 * scale >> 24`.
    function _vmCurrentBalanceIn(OrderSpec memory spec) internal view returns (uint256) {
        (uint40 ts, uint16[] memory durations, uint24[] memory scales) = _vmScales(spec);
        uint256 start = ts;
        uint256 finish = start + durations[0];
        uint256 balanceIn0 = PiecewiseLinearScaleArgsBuilder.unscaleValue(spec.takingAmount, scales[1]);

        uint256 scale; // the (+1) multiplier numerator _calcScaleNow returns; applied as balanceIn0 * scale >> 24
        if (block.timestamp <= start) {
            scale = uint256(scales[0]) + 1;
        } else if (block.timestamp >= finish) {
            scale = uint256(scales[1]) + 1;
        } else {
            uint256 timeLeft = block.timestamp - start;
            uint256 duration = durations[0];
            scale = (timeLeft * scales[1] + (duration - timeLeft) * scales[0]) / duration + 1;
        }
        return (balanceIn0 * scale) >> 24;
    }

    /// @notice The Fusion taker-asset input that buys the full makingAmount at the current block.timestamp —
    ///         SimpleSettlement's `takingAmount * (1e7 + bump) / 1e7` (ceil), the exact-in counterpart of the
    ///         exact-out full buy. Recomputes the single-segment rate bump (no gas bump).
    function _fusionCurrentTakingIn(OrderSpec memory spec) internal view returns (uint256) {
        uint256 start = spec.auctionStartTime;
        uint256 finish = start + spec.auctionDuration;

        uint256 bump;
        if (block.timestamp <= start) {
            bump = spec.initialRateBump;
        } else if (block.timestamp >= finish) {
            bump = 0;
        } else {
            bump = (finish - block.timestamp) * spec.initialRateBump / (finish - start);
        }
        uint256 numerator = spec.takingAmount * (FUSION_BASE_POINTS + bump);
        return (numerator + FUSION_BASE_POINTS - 1) / FUSION_BASE_POINTS; // ceil
    }

    /// @notice Translate `spec` into the SwapVM program that replicates the Fusion order: static balances ->
    ///         piecewise scale of balanceIn (the auction) -> invalidator + linear swap (matching LOP's
    ///         bit- vs remaining-invalidator selection). `balanceIn` is anchored so that at the finish scale
    ///         it reproduces `takingAmount` exactly; `balanceOut` is the full makingAmount.
    function _vmProgram(OrderSpec memory spec) internal view returns (bytes memory) {
        (uint40 timestamp, uint16[] memory durations, uint24[] memory scales) = _vmScales(spec);

        address tokenIn = takerAssetToken;
        address tokenOut = makerAssetToken;
        uint256 balanceIn = PiecewiseLinearScaleArgsBuilder.unscaleValue(spec.takingAmount, scales[1]);

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([tokenIn, tokenOut]), dynamic([balanceIn, spec.makingAmount]))),
            p.build(_piecewiseLinearScaleBalanceIn1D, PiecewiseLinearScaleArgsBuilder.build(timestamp, durations, scales))
        );

        if (!spec.allowPartialFills) {
            program = bytes.concat(
                program,
                p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(0)),
                p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
            );
        } else if (!spec.allowMultipleFills) {
            program = bytes.concat(
                program,
                p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(0)),
                p.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
            );
        } else {
            program = bytes.concat(
                program,
                p.build(_invalidateTokenOut1D),
                p.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
            );
        }
        return program;
    }

    /// @notice Build the SwapVM order for `spec` (signature-mode maker order).
    function _vmOrder(OrderSpec memory spec) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            tokenA: takerAssetToken,
            tokenB: makerAssetToken,
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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
            program: _vmProgram(spec)
        }));
    }

    /// @notice Build SwapVM taker data (signs the SwapVM order with the maker key).
    function _vmTakerData(ISwapVM.Order memory order, FillSpec memory fs) internal view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            getTokenBForTokenA: true, // takerAsset == tokenA == tokenIn
            isExactIn: !fs.byMakingAmount, // VM exactIn <=> LOP fills by taking amount
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: (fs.hasThreshold && fs.threshold > 0) ? abi.encodePacked(bytes32(fs.threshold)) : bytes(""),
            to: address(this),
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
            signature: signature
        }));
    }

    // =============================================================================================
    // Execution helpers — each returns the platform's (makerAssetOut, takerAssetIn) outcome.
    // =============================================================================================

    struct FillResult {
        bool ok;
        uint256 makerAssetOut; // LOP makingAmount / SwapVM amountOut (tokenB to taker)
        uint256 takerAssetIn;  // LOP takingAmount / SwapVM amountIn  (tokenA from taker)
        uint256 gasUsed;       // gas consumed by the fill *call itself* (the end call), 0 on revert
    }

    /// @notice Fill `spec`/`fs` against the real Fusion settlement order; never reverts (captures success).
    function _fillFusion(OrderSpec memory spec, FillSpec memory fs) internal returns (FillResult memory res) {
        (IOrderMixin.Order memory order, bytes32 r, bytes32 vs, bytes memory extension) = _fusionOrder(spec);
        TakerTraits tt = _fusionTakerTraits(fs, extension.length);
        uint256 g = gasleft();
        try lop.fillOrderArgs(order, r, vs, fs.amount, tt, extension) returns (uint256 making, uint256 taking, bytes32) {
            uint256 used = g - gasleft();
            res = FillResult({ ok: true, makerAssetOut: making, takerAssetIn: taking, gasUsed: used });
        } catch {
            res = FillResult({ ok: false, makerAssetOut: 0, takerAssetIn: 0, gasUsed: 0 });
        }
    }

    /// @notice Fill the SwapVM replica of `spec`/`fs`; never reverts (captures success).
    function _fillVm(OrderSpec memory spec, FillSpec memory fs) internal returns (FillResult memory res) {
        ISwapVM.Order memory order = _vmOrder(spec);
        bytes memory takerData = _vmTakerData(order, fs);
        uint256 g = gasleft();
        try swapVM.swap(order, fs.amount, takerData) returns (uint256 amountIn, uint256 amountOut, bytes32) {
            uint256 used = g - gasleft();
            res = FillResult({ ok: true, makerAssetOut: amountOut, takerAssetIn: amountIn, gasUsed: used });
        } catch {
            res = FillResult({ ok: false, makerAssetOut: 0, takerAssetIn: 0, gasUsed: 0 });
        }
    }

    // =============================================================================================
    // Drift-free gas metering (each fill runs in its OWN external call frame so the metered CALL's
    // memory-expansion cost is constant, not inflated by the caller loop's accumulated memory; see
    // LopParityBase for the full rationale). Wrap calls in vm.snapshotState/revertToState for per-order
    // cold-slot isolation. Reverts if the fill fails.
    // =============================================================================================

    /// @notice Gas of one SwapVM fill of `spec`/`fs`, metered in a fresh frame (no loop drift).
    function meterVmFill(OrderSpec calldata spec, FillSpec calldata fs) external returns (uint256 gasUsed) {
        ISwapVM.Order memory order = _vmOrder(spec);
        bytes memory takerData = _vmTakerData(order, fs);
        uint256 g = gasleft();
        swapVM.swap(order, fs.amount, takerData);
        gasUsed = g - gasleft();
    }

    /// @notice Gas of one Fusion settlement fill of `spec`/`fs`, metered in a fresh frame (no loop drift).
    function meterFusionFill(OrderSpec calldata spec, FillSpec calldata fs) external returns (uint256 gasUsed) {
        (IOrderMixin.Order memory order, bytes32 r, bytes32 vs, bytes memory extension) = _fusionOrder(spec);
        TakerTraits tt = _fusionTakerTraits(fs, extension.length);
        uint256 g = gasleft();
        lop.fillOrderArgs(order, r, vs, fs.amount, tt, extension);
        gasUsed = g - gasleft();
    }
}
