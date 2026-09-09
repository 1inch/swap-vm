// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { AquaSwapVMRouter } from "../../../contracts/routers/AquaSwapVMRouter.sol";
import { MakerTraitsLib } from "../../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../contracts/libs/TakerTraits.sol";
import { XYCConcentrateSwap } from "../../../contracts/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../../../contracts/instructions/XYCSwap.sol";
import { PeggedSwap } from "../../../contracts/instructions/PeggedSwap.sol";
import { Decay } from "../../../contracts/instructions/Decay.sol";
import { FeeFlatIn } from "../../../contracts/instructions/FeeFlat.sol";
import { dynamic } from "../utils/Dynamic.sol";

/// @title AquaRouterGas
/// @notice Aqua-backed AMM gas benchmarks.
contract AquaRouterGas is Test {
    Aqua public immutable aqua = new Aqua();
    AquaSwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;

    uint256 constant AMM_BALANCE = 1000e18;
    uint256 constant SWAP_AMOUNT = 1e18;

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        swapVM = new AquaSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token I", "TKI");
        tokenB = new TokenMock("Token J", "TKJ");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        tokenA.mint(maker, 1e30);
        tokenB.mint(maker, 1e30);
        vm.prank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(aqua), type(uint256).max);

        tokenA.mint(taker, 1e30);
        tokenB.mint(taker, 1e30);
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_gas_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programXYCSwap(true);
        snapshotQuote("AquaRouterQuote", "XYCSwap_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programXYCSwap(true);
        snapshotSwap("AquaRouterSwap", "XYCSwap_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programXYCSwap(false);
        snapshotQuote("AquaRouterQuote", "XYCSwap_exactOut", order, takerData);
    }

    function test_gas_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programXYCSwap(false);
        snapshotSwap("AquaRouterSwap", "XYCSwap_exactOut", order, takerData);
    }

    function test_gas_PeggedSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programPeggedSwap(true);
        snapshotQuote("AquaRouterQuote", "PeggedSwap_exactIn", order, takerData);
    }

    function test_gas_PeggedSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programPeggedSwap(true);
        snapshotSwap("AquaRouterSwap", "PeggedSwap_exactIn", order, takerData);
    }

    function test_gas_PeggedSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programPeggedSwap(false);
        snapshotQuote("AquaRouterQuote", "PeggedSwap_exactOut", order, takerData);
    }

    function test_gas_PeggedSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programPeggedSwap(false);
        snapshotSwap("AquaRouterSwap", "PeggedSwap_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowLiquidityXYCSwap(true);
        snapshotQuote("AquaRouterQuote", "ConcentrateGrowLiquidity_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowLiquidityXYCSwap(true);
        snapshotSwap("AquaRouterSwap", "ConcentrateGrowLiquidity_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowLiquidityXYCSwap(false);
        snapshotQuote("AquaRouterQuote", "ConcentrateGrowLiquidity_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowLiquidity_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowLiquidityXYCSwap(false);
        snapshotSwap("AquaRouterSwap", "ConcentrateGrowLiquidity_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowPriceRangeXYCSwap(true);
        snapshotQuote("AquaRouterQuote", "ConcentrateGrowPriceRange_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowPriceRangeXYCSwap(true);
        snapshotSwap("AquaRouterSwap", "ConcentrateGrowPriceRange_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowPriceRangeXYCSwap(false);
        snapshotQuote("AquaRouterQuote", "ConcentrateGrowPriceRange_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_ConcentrateGrowPriceRange_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateGrowPriceRangeXYCSwap(false);
        snapshotSwap("AquaRouterSwap", "ConcentrateGrowPriceRange_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_Decay_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDecayXYCSwap(true);
        snapshotQuote("AquaRouterQuote", "Decay_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_Decay_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDecayXYCSwap(true);
        snapshotSwap("AquaRouterSwap", "Decay_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_Decay_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDecayXYCSwap(false);
        snapshotQuote("AquaRouterQuote", "Decay_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_Decay_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programDecayXYCSwap(false);
        snapshotSwap("AquaRouterSwap", "Decay_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_Concentrate_Decay_XYCSwap_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateDecayXYCSwap(true);
        snapshotQuote("AquaRouterQuote", "Concentrate_Decay_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_Concentrate_Decay_XYCSwap_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateDecayXYCSwap(true);
        snapshotSwap("AquaRouterSwap", "Concentrate_Decay_XYCSwap_exactIn", order, takerData);
    }

    function test_gas_Concentrate_Decay_XYCSwap_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateDecayXYCSwap(false);
        snapshotQuote("AquaRouterQuote", "Concentrate_Decay_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_Concentrate_Decay_XYCSwap_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programConcentrateDecayXYCSwap(false);
        snapshotSwap("AquaRouterSwap", "Concentrate_Decay_XYCSwap_exactOut", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeIn_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFlatFeeInXYCSwap(true);
        snapshotQuote("AquaRouterQuote", "XYCSwap_FlatFeeIn_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeIn_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFlatFeeInXYCSwap(true);
        snapshotSwap("AquaRouterSwap", "XYCSwap_FlatFeeIn_exactIn", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeIn_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFlatFeeInXYCSwap(false);
        snapshotQuote("AquaRouterQuote", "XYCSwap_FlatFeeIn_exactOut", order, takerData);
    }

    function test_gas_XYCSwap_FlatFeeIn_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFlatFeeInXYCSwap(false);
        snapshotSwap("AquaRouterSwap", "XYCSwap_FlatFeeIn_exactOut", order, takerData);
    }

    function test_gas_FullAMM_quote_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullAMM(true);
        snapshotQuote("AquaRouterQuote", "FullAMM_exactIn", order, takerData);
    }

    function test_gas_FullAMM_swap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullAMM(true);
        snapshotSwap("AquaRouterSwap", "FullAMM_exactIn", order, takerData);
    }

    function test_gas_FullAMM_quote_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullAMM(false);
        snapshotQuote("AquaRouterQuote", "FullAMM_exactOut", order, takerData);
    }

    function test_gas_FullAMM_swap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = programFullAMM(false);
        snapshotSwap("AquaRouterSwap", "FullAMM_exactOut", order, takerData);
    }

    function snapshotQuote(
        string memory group,
        string memory name,
        ISwapVM.Order memory order,
        bytes memory takerData
    ) internal {
        swapVM.asView().quote(order, SWAP_AMOUNT, takerData);
        uint256 gasUsed = uint256(vm.lastCallGas().gasTotalUsed);
        vm.snapshotValue(
            group,
            name,
            gasUsed + calldataGas(abi.encodeCall(ISwapVM.quote, (order, SWAP_AMOUNT, takerData)))
        );
    }

    function snapshotSwap(
        string memory group,
        string memory name,
        ISwapVM.Order memory order,
        bytes memory takerData
    ) internal {
        swapVM.swap(order, SWAP_AMOUNT, takerData);
        uint256 gasUsed = uint256(vm.lastCallGas().gasTotalUsed);
        vm.snapshotValue(
            group,
            name,
            gasUsed + calldataGas(abi.encodeCall(ISwapVM.swap, (order, SWAP_AMOUNT, takerData)))
        );
    }

    function calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function concentrateBalances(uint256 available, uint256 sqrtPmin, uint256 sqrtPmax)
        internal
        view
        returns (uint256 balA, uint256 balB)
    {
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateSwap.computeLiquidityFromAmounts(available, available, 1e18, sqrtPmin, sqrtPmax);
        (balA, balB) = address(tokenA) < address(tokenB) ? (actualLt, actualGt) : (actualGt, actualLt);
    }

    function programXYCSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(XYCSwap.build(), isExactIn, AMM_BALANCE, AMM_BALANCE);
    }

    function programPeggedSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(
            PeggedSwap.build(AMM_BALANCE, AMM_BALANCE, 100e27, 1, 1),
            isExactIn,
            AMM_BALANCE,
            AMM_BALANCE
        );
    }

    function programFlatFeeInXYCSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(bytes.concat(FeeFlatIn.build(100), XYCSwap.build()), isExactIn, AMM_BALANCE, AMM_BALANCE);
    }

    function programConcentrateGrowLiquidityXYCSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balA, uint256 balB) = concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return buildOrder(XYCConcentrateSwap.build(sqrtPmin, sqrtPmax), isExactIn, balA, balB);
    }

    function programConcentrateGrowPriceRangeXYCSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.7e36);
        uint256 sqrtPmax = Math.sqrt(1.4e36);
        (uint256 balA, uint256 balB) = concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return buildOrder(XYCConcentrateSwap.build(sqrtPmin, sqrtPmax), isExactIn, balA, balB);
    }

    function programDecayXYCSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        return buildOrder(bytes.concat(Decay.build(3600), XYCSwap.build()), isExactIn, AMM_BALANCE, AMM_BALANCE);
    }

    function programConcentrateDecayXYCSwap(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balA, uint256 balB) = concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return buildOrder(bytes.concat(Decay.build(3600), XYCConcentrateSwap.build(sqrtPmin, sqrtPmax)), isExactIn, balA, balB);
    }

    function programFullAMM(bool isExactIn) internal returns (ISwapVM.Order memory, bytes memory) {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balA, uint256 balB) = concentrateBalances(AMM_BALANCE, sqrtPmin, sqrtPmax);
        return buildOrder(
            bytes.concat(Decay.build(3600), FeeFlatIn.build(30), XYCConcentrateSwap.build(sqrtPmin, sqrtPmax)),
            isExactIn,
            balA,
            balB
        );
    }

    function buildOrder(
        bytes memory program,
        bool isExactIn,
        uint256 balanceA,
        uint256 balanceB
    ) internal returns (ISwapVM.Order memory order, bytes memory takerData) {
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
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
            program: program
        }));

        bytes32 orderHash = swapVM.hash(order);
        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([balanceA, balanceB])
        );
        assertEq(strategyHash, orderHash);

        takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: true,
            allowPartialFill: false,
            threshold: "",
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
            signature: ""
        }));
    }
}
