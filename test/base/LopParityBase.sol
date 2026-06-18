// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

// ---- SwapVM side ----
import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../../src/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { LimitOpcodesDebug } from "../../src/opcodes/LimitOpcodesDebug.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";
import { InvalidatorsArgsBuilder } from "../../src/instructions/Invalidators.sol";
import { ControlsArgsBuilder } from "../../src/instructions/Controls.sol";
import { WhitelistArgsBuilder } from "../../src/instructions/Whitelist.sol";
import { SeriesEpochManagerArgsBuilder } from "../../src/instructions/SeriesEpochManager.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { dynamic } from "../utils/Dynamic.sol";
import { InteractionRecorderMock } from "../mocks/InteractionRecorderMock.sol";

// ---- LOP side (real Limit Order Protocol, compiled from sibling repo via @1inch/limit-order-protocol/ remapping) ----
import { LimitOrderProtocol } from "@1inch/limit-order-protocol/LimitOrderProtocol.sol";
import { IOrderMixin } from "@1inch/limit-order-protocol/interfaces/IOrderMixin.sol";
import { MakerTraits } from "@1inch/limit-order-protocol/libraries/MakerTraitsLib.sol";
import { TakerTraits } from "@1inch/limit-order-protocol/libraries/TakerTraitsLib.sol";
import { Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import { WrappedTokenMock } from "@1inch/limit-order-protocol/mocks/WrappedTokenMock.sol";

/// @title  LopParityBase
/// @notice Differential-test scaffolding that replicates a 1inch Limit Order Protocol base limit
///         order as an equivalent SwapVM program, then exposes builders for both platforms so a test
///         can fill the *same* economic order on each and compare results.
///
///         The flow mirrors what a real integrator would do:
///           1. deploy the real LimitOrderProtocol contract;
///           2. describe an order with a platform-agnostic {OrderSpec};
///           3. translate the spec into an LOP order (+ maker signature) and into a SwapVM program;
///           4. describe a fill with a platform-agnostic {FillSpec};
///           5. translate the fill into LOP TakerTraits and SwapVM taker data;
///           6. run both and compare (done by the concrete test).
///
/// @dev    Token mapping (see memory lop-swapvm-limit-mapping):
///           makerAsset == tokenB == SwapVM tokenOut (the taker receives it)
///           takerAsset == tokenA == SwapVM tokenIn  (the taker provides it)
///         so LOP `makingAmount` == SwapVM `amountOut` and LOP `takingAmount` == SwapVM `amountIn`.
///
///         The LOP builder ({_lopMakerTraits}/{_lopOrder}) supports the FULL MakerTraits surface.
///         SwapVM replicates: linear amounts & rounding, partial/multiple fills, thresholds, expiry,
///         maker pre/post-interactions (== SwapVM maker hooks), private orders (== _whitelistSingleTaker),
///         epoch management (== _validateSeriesEpochXD), and maker-side WETH unwrap (== shouldUnwrapWeth,
///         dedicated test). {_swapVmReplicable} reports which specs have a VM equivalent.
///
///         Genuine remaining gaps (no SwapVM equivalent): permit2; and a taker paying *native ETH*
///         (LOP wraps msg.value; SwapVM.swap is not payable). Plus, within the replicable set, LOP's
///         over-request *clamping* (LOP clamps a too-large fill to the remainder and succeeds, SwapVM
///         reverts) — so callers MUST keep each requested fill <= remaining size.
abstract contract LopParityBase is Test, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    /// @notice Description of a maker's limit order, covering the FULL LOP MakerTraits surface.
    /// @dev    Every field maps 1:1 onto a MakerTraits bit/slice (see {_lopMakerTraits}); the builder
    ///         encodes whatever is set here. SwapVM can only replicate a subset — {_swapVmReplicable}
    ///         reports whether a given spec has a SwapVM equivalent, and the differential tests skip
    ///         specs that don't.
    struct OrderSpec {
        uint256 makingAmount;      // makerAsset (tokenB) the maker offers — taker receives this
        uint256 takingAmount;      // takerAsset (tokenA) the maker wants  — taker provides this
        // ---- MakerTraits low 200 bits ----
        address allowedSender;     // private order: only this taker may fill (0 = public). LOP uses low 80 bits.
        uint40 expiry;             // 0 = no expiry; else order valid while block.timestamp <= expiry
        uint40 nonceOrEpoch;       // bit-invalidator: the invalidation bit index; epoch orders: the epoch
        uint40 series;             // epoch series id (only meaningful with needCheckEpoch)
        // ---- MakerTraits flags (bits 247..255) ----
        bool allowPartialFills;    // !NO_PARTIAL_FILLS  ; SwapVM: limitSwap1D vs limitSwapOnlyFull1D
        bool allowMultipleFills;   // ALLOW_MULTIPLE_FILLS ; SwapVM: tokenOut- vs bit-invalidator
        bool needCheckEpoch;       // NEED_CHECK_EPOCH_MANAGER (no SwapVM equivalent)
        bool usePermit2;           // USE_PERMIT2 (no SwapVM equivalent)
        bool unwrapWeth;           // UNWRAP_WETH (no SwapVM equivalent here; needs WETH maker asset)
        // ---- Maker interactions (LOP pre/post-interaction == SwapVM maker hooks) ----
        bool preInteraction;       // PRE_INTERACTION_CALL  -> SwapVM preTransferOut hook (fires before transfers)
        bool postInteraction;      // POST_INTERACTION_CALL -> SwapVM postTransferIn hook (fires after transfers)
        bytes preInteractionData;  // maker-supplied payload handed to the pre interaction/hook
        bytes postInteractionData; // maker-supplied payload handed to the post interaction/hook
        // HAS_EXTENSION is not a free-standing field: the LOP builder sets it automatically whenever an
        // extension is actually produced (i.e. when an interaction is present), keeping salt/flags valid.
    }

    /// @notice Platform-agnostic description of a single taker fill.
    struct FillSpec {
        bool byMakingAmount;       // true  => `amount` is makerAsset out (LOP isMakingAmount / VM exactOut)
                                   // false => `amount` is takerAsset in  (LOP !isMakingAmount / VM exactIn)
        uint256 amount;            // requested fill amount (interpreted per byMakingAmount)
        bool hasThreshold;         // whether a rate-protection threshold is supplied
        uint256 threshold;         // exactOut: max takerAsset in ; exactIn: min makerAsset out
    }

    Aqua public immutable aqua;

    // Shared participants and tokens (both platforms operate on the same balances; tests compare
    // per-fill deltas, so sharing is safe and keeps the economic order identical on each side).
    uint256 public constant MAKER_PK = 0xA11CE;
    address public maker;
    address public taker; // = address(this)

    LimitSwapVMRouter public swapVM;
    LimitOrderProtocol public lop;
    IWETH public weth;

    TokenMock public tokenA; // takerAsset / tokenIn
    TokenMock public tokenB; // makerAsset / tokenOut

    // The token addresses the builders use for takerAsset/tokenIn and makerAsset/tokenOut. Default to
    // tokenA/tokenB; a test can repoint takerAssetToken at WETH to exercise maker UNWRAP_WETH.
    address public takerAssetToken;
    address public makerAssetToken;

    /// @dev Shared interaction target for both platforms' maker hooks (records each call's data).
    InteractionRecorderMock public recorder;

    /// @dev A fixed, non-zero base timestamp so expiry arithmetic has head- and tail-room.
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

        recorder = new InteractionRecorderMock();

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
    // LOP builders
    // =============================================================================================

    function _toAddress(address a) internal pure returns (Address) {
        return Address.wrap(uint256(uint160(a)));
    }

    // MakerTraits bit layout (verified against @1inch/limit-order-protocol MakerTraitsLib).
    uint256 private constant _NO_PARTIAL_FILLS_FLAG = 1 << 255;
    uint256 private constant _ALLOW_MULTIPLE_FILLS_FLAG = 1 << 254;
    uint256 private constant _PRE_INTERACTION_CALL_FLAG = 1 << 252;
    uint256 private constant _POST_INTERACTION_CALL_FLAG = 1 << 251;
    uint256 private constant _NEED_CHECK_EPOCH_MANAGER_FLAG = 1 << 250;
    uint256 private constant _HAS_EXTENSION_FLAG = 1 << 249;
    uint256 private constant _USE_PERMIT2_FLAG = 1 << 248;
    uint256 private constant _UNWRAP_WETH_FLAG = 1 << 247;
    uint256 private constant _SERIES_OFFSET = 160;
    uint256 private constant _NONCE_OR_EPOCH_OFFSET = 120;
    uint256 private constant _EXPIRATION_OFFSET = 80;
    uint256 private constant _ALLOWED_SENDER_MASK = type(uint80).max;

    /// @notice Faithfully pack the FULL LOP MakerTraits for `spec` — every flag and slice, exactly as
    ///         LOP's own `buildMakerTraits` helper does. The builder honours whatever the spec sets.
    function _lopMakerTraits(OrderSpec memory spec) internal pure returns (MakerTraits) {
        uint256 mt = 0;
        if (!spec.allowPartialFills) mt |= _NO_PARTIAL_FILLS_FLAG;
        if (spec.allowMultipleFills) mt |= _ALLOW_MULTIPLE_FILLS_FLAG;
        if (spec.preInteraction)     mt |= _PRE_INTERACTION_CALL_FLAG;
        if (spec.postInteraction)    mt |= _POST_INTERACTION_CALL_FLAG;
        if (spec.needCheckEpoch)     mt |= _NEED_CHECK_EPOCH_MANAGER_FLAG;
        // HAS_EXTENSION is implied by the presence of an interaction (the only extension field we build).
        if (spec.preInteraction || spec.postInteraction) mt |= _HAS_EXTENSION_FLAG;
        if (spec.usePermit2)         mt |= _USE_PERMIT2_FLAG;
        if (spec.unwrapWeth)         mt |= _UNWRAP_WETH_FLAG;
        mt |= uint256(spec.series) << _SERIES_OFFSET;
        mt |= uint256(spec.nonceOrEpoch) << _NONCE_OR_EPOCH_OFFSET;
        mt |= uint256(spec.expiry) << _EXPIRATION_OFFSET;
        mt |= uint256(uint160(spec.allowedSender)) & _ALLOWED_SENDER_MASK;
        return MakerTraits.wrap(mt);
    }

    /// @notice Build the LOP extension blob carrying the maker interactions for `spec` (empty if none).
    /// @dev    Extension layout is an 8x uint32 offsets header followed by the concatenated dynamic
    ///         fields; here only PreInteractionData (field 6) and PostInteractionData (field 7) are
    ///         populated. Each interaction field is `target(20) ++ extraData`, matching LOP's
    ///         preInteractionTargetAndData parsing (listener = first 20 bytes, extraData = the rest).
    function _lopExtension(OrderSpec memory spec) internal view returns (bytes memory) {
        if (!spec.preInteraction && !spec.postInteraction) return "";

        bytes memory pre = spec.preInteraction ? abi.encodePacked(address(recorder), spec.preInteractionData) : bytes("");
        bytes memory post = spec.postInteraction ? abi.encodePacked(address(recorder), spec.postInteractionData) : bytes("");

        uint256 end6 = pre.length;               // cumulative end of field 6 (PreInteractionData)
        uint256 end7 = pre.length + post.length;  // cumulative end of field 7 (PostInteractionData)
        uint256 offsets = (end6 << 192) | (end7 << 224); // uint32 slots 6 and 7; slots 0..5 stay zero
        return abi.encodePacked(bytes32(offsets), pre, post);
    }

    /// @notice Build the real LOP order for `spec`, its extension, and the maker's compact signature.
    /// @dev    When an extension is present, HAS_EXTENSION is set (in {_lopMakerTraits}) and the order
    ///         salt's low 160 bits are bound to the extension hash, as LOP's isValidExtension requires.
    function _lopOrder(OrderSpec memory spec)
        internal
        view
        returns (IOrderMixin.Order memory order, bytes32 r, bytes32 vs, bytes memory extension)
    {
        extension = _lopExtension(spec);

        uint256 salt = uint256(keccak256(abi.encode(spec)));
        if (extension.length > 0) {
            salt = (salt & ~uint256(type(uint160).max)) | (uint256(keccak256(extension)) & type(uint160).max);
        }

        order = IOrderMixin.Order({
            salt: salt,
            maker: _toAddress(maker),
            receiver: _toAddress(address(0)), // 0 => proceeds go to maker
            makerAsset: _toAddress(makerAssetToken),
            takerAsset: _toAddress(takerAssetToken),
            makingAmount: spec.makingAmount,
            takingAmount: spec.takingAmount,
            makerTraits: _lopMakerTraits(spec)
        });

        bytes32 orderHash = lop.hashOrder(order);
        uint8 v;
        bytes32 s;
        (v, r, s) = vm.sign(MAKER_PK, orderHash);
        vs = bytes32(uint256(s) | (uint256(v - 27) << 255)); // EIP-2098 compact signature
    }

    /// @notice A plain public single-series order with all advanced MakerTraits left off — the common
    ///         case for the linear/partial/threshold/expiry parity tests.
    function _baseSpec(
        uint256 makingAmount,
        uint256 takingAmount,
        bool allowPartialFills,
        bool allowMultipleFills,
        uint40 expiry
    ) internal pure returns (OrderSpec memory s) {
        s.makingAmount = makingAmount;
        s.takingAmount = takingAmount;
        s.allowPartialFills = allowPartialFills;
        s.allowMultipleFills = allowMultipleFills;
        s.expiry = expiry;
        // allowedSender/nonceOrEpoch/series default 0; all advanced flags default false.
    }

    /// @notice Whether the SwapVM replica can reproduce this order *in the generic harness* (whose
    ///         takerAsset is a plain ERC20). Replicable: linear/partial/multiple/threshold/expiry, maker
    ///         interactions (hooks), private orders (Whitelist._whitelistSingleTaker), and epoch
    ///         management (SeriesEpochManager._validateSeriesEpochXD).
    ///
    ///         Not replicable here:
    ///         - permit2: no SwapVM equivalent.
    ///         - unwrapWeth: maker-side WETH unwrap IS fully supported (SwapVM shouldUnwrapWeth ==
    ///           LOP makerTraits.unwrapWeth, proven by test_UnwrapWeth_*). It's only skipped here because
    ///           the generic takerAsset is a plain ERC20, where the flag is meaningless: LOP no-ops it
    ///           (needUnwrap requires takerAsset==WETH) while SwapVM would call withdraw() on a non-WETH
    ///           token and revert. That divergence is a misconfigured order, not a capability gap.
    ///         (The one genuine WETH gap — a taker paying *native ETH* via msg.value, which LOP wraps —
    ///          has no SwapVM equivalent at all, since swap() is not payable. The harness never uses it.)
    ///
    ///         Epoch orders must be partial+multiple because LOP forbids combining the epoch manager with
    ///         the bit invalidator.
    function _swapVmReplicable(OrderSpec memory spec) internal pure returns (bool) {
        if (spec.usePermit2) return false;
        if (spec.unwrapWeth) return false; // meaningless on the generic plain-ERC20 takerAsset (see above)
        if (spec.needCheckEpoch && (!spec.allowPartialFills || !spec.allowMultipleFills)) return false;
        return true;
    }

    uint256 private constant _MAKER_AMOUNT_FLAG = 1 << 255;
    uint256 private constant _ARGS_EXTENSION_LENGTH_OFFSET = 224;

    /// @notice Build LOP TakerTraits from a fill spec, encoding the extension length so fillOrderArgs
    ///         knows how many leading bytes of `args` are the extension.
    function _lopTakerTraits(FillSpec memory fs, uint256 extensionLength) internal pure returns (TakerTraits) {
        uint256 tt = fs.hasThreshold ? fs.threshold : 0; // low 200 bits hold the threshold
        if (fs.byMakingAmount) tt |= _MAKER_AMOUNT_FLAG;
        tt |= extensionLength << _ARGS_EXTENSION_LENGTH_OFFSET;
        return TakerTraits.wrap(tt);
    }

    // =============================================================================================
    // SwapVM builders
    // =============================================================================================

    /// @notice Translate `spec` into the SwapVM program that replicates the LOP order.
    function _vmProgram(OrderSpec memory spec) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        address tokenIn = takerAssetToken;
        address tokenOut = makerAssetToken;

        // balanceIn = takingAmount, balanceOut = makingAmount (linear rate).
        bytes memory program = p.build(
            _staticBalancesXD,
            BalancesArgsBuilder.build(dynamic([tokenIn, tokenOut]), dynamic([spec.takingAmount, spec.makingAmount]))
        );

        // Maker-side expiry == LOP order expiration.
        if (spec.expiry != 0) {
            program = bytes.concat(program, p.build(_deadline, ControlsArgsBuilder.buildDeadline(spec.expiry)));
        }

        // Private order: only the whitelisted taker may fill (== LOP allowedSender).
        if (spec.allowedSender != address(0)) {
            program = bytes.concat(
                program,
                p.build(_whitelistSingleTaker, WhitelistArgsBuilder.buildWhitelistSingleTaker(spec.allowedSender))
            );
        }

        // Epoch management: order valid only while the maker's epoch for the series matches (== LOP
        // needCheckEpochManager + series/nonceOrEpoch). seriesId/epoch are uint32 in the instruction.
        if (spec.needCheckEpoch) {
            program = bytes.concat(
                program,
                p.build(
                    _validateSeriesEpochXD,
                    SeriesEpochManagerArgsBuilder.buildEpochValidation(uint32(spec.series), uint32(spec.nonceOrEpoch))
                )
            );
        }

        // Invalidator + swap, chosen to match LOP's bit- vs remaining-invalidator selection.
        if (!spec.allowPartialFills) {
            // Full-fill-only, single shot.
            program = bytes.concat(
                program,
                p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(spec.nonceOrEpoch))),
                p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
            );
        } else if (!spec.allowMultipleFills) {
            // Single fill, may be partial.
            program = bytes.concat(
                program,
                p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(uint32(spec.nonceOrEpoch))),
                p.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
            );
        } else {
            // Partial + multiple fills, cumulative output capped at makingAmount.
            program = bytes.concat(
                program,
                p.build(_invalidateTokenOut1D),
                p.build(_limitSwap1D, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
            );
        }
        return program;
    }

    /// @notice Build the SwapVM order for `spec` (signature-mode maker order).
    /// @dev    Maker-interaction mapping: LOP preInteraction (before any transfer) -> preTransferOut
    ///         hook (the first hook in the default taker order: transferOut then transferIn); LOP
    ///         postInteraction (after all transfers) -> postTransferIn hook (the last hook). The same
    ///         maker payload bytes are handed to the hook as LOP hands to its interaction.
    function _vmOrder(OrderSpec memory spec) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            // tokenA == takerAsset == tokenIn, tokenB == makerAsset == tokenOut (see header docs);
            // a test may repoint takerAssetToken at WETH, so derive both from the repointable vars.
            tokenA: takerAssetToken,
            tokenB: makerAssetToken,
            maker: maker,
            // Maker receives tokenIn as ETH when set & tokenIn is WETH — the signature-path equivalent
            // of LOP's makerTraits.unwrapWeth() (see SwapVM._transferFrom; incompatible with Aqua).
            shouldUnwrapWeth: spec.unwrapWeth,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: spec.postInteraction,
            hasPreTransferOutHook: spec.preInteraction,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: spec.postInteraction ? address(recorder) : address(0),
            postTransferInData: spec.postInteraction ? spec.postInteractionData : bytes(""),
            preTransferOutTarget: spec.preInteraction ? address(recorder) : address(0),
            preTransferOutData: spec.preInteraction ? spec.preInteractionData : bytes(""),
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
            // A zero threshold means "no rate protection" — LOP gates its threshold check on
            // `threshold > 0`, so to stay in parity the VM order must carry no threshold either.
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

    /// @notice Fill `spec`/`fs` against the real LOP contract; never reverts (captures success).
    /// @dev    Uses fillOrderArgs so the order's extension (maker interactions) can be supplied; for
    ///         plain orders the extension is empty and this behaves like fillOrder.
    function _fillLop(OrderSpec memory spec, FillSpec memory fs) internal returns (FillResult memory res) {
        (IOrderMixin.Order memory order, bytes32 r, bytes32 vs, bytes memory extension) = _lopOrder(spec);
        TakerTraits tt = _lopTakerTraits(fs, extension.length);
        // Measure only the fill call itself (the "end call"), not order building/signing above.
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
        // Measure only the swap call itself (the "end call"), not order building/signing above.
        uint256 g = gasleft();
        try swapVM.swap(order, fs.amount, takerData)
            returns (uint256 amountIn, uint256 amountOut, bytes32)
        {
            uint256 used = g - gasleft();
            res = FillResult({ ok: true, makerAssetOut: amountOut, takerAssetIn: amountIn, gasUsed: used });
        } catch {
            res = FillResult({ ok: false, makerAssetOut: 0, takerAssetIn: 0, gasUsed: 0 });
        }
    }
}
