// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BridgeTestBase} from "./../../aztec/base/BridgeTestBase.sol";
import {AztecTypes} from "../../../aztec/libraries/AztecTypes.sol";

// JB-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ErrorLib} from "../../../bridges/base/ErrorLib.sol";
import {JuiceboxBridge} from "../../../bridges/juicebox/JuiceboxBridge.sol";
import {IJBPayoutRedemptionPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol";

// @notice The purpose of this test is to directly test convert functionality of the bridge.
contract JuiceboxBridgeUnitTest is BridgeTestBase {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant BENEFICIARY = address(11);

    address private rollupProcessor;
    // The reference to the example bridge
    JuiceboxBridge private bridge;

    // @dev This method exists on RollupProcessor.sol. It's defined here in order to be able to receive ETH like a real
    //      rollup processor would.
    function receiveEthFromBridge(uint256 _interactionNonce) external payable {}

    function setUp() public {
        // In unit tests we set address of rollupProcessor to the address of this test contract
        rollupProcessor = address(this);

        // Deploy a new example bridge
        bridge = new JuiceboxBridge(rollupProcessor);

        // Set ETH balance of bridge and BENEFICIARY to 0 for clarity (somebody sent ETH to that address on mainnet)
        vm.deal(address(bridge), 0);
        vm.deal(BENEFICIARY, 0);

        // Use the label cheatcode to mark the address with "Example Bridge" in the traces
        vm.label(address(bridge), "Juicebox Bridge");

        // Subsidize the bridge when used with Dai and register a beneficiary
        AztecTypes.AztecAsset memory daiAsset = getRealAztecAsset(DAI);
        uint256 criteria = bridge.computeCriteria(daiAsset, emptyAsset, daiAsset, emptyAsset, 0);
        uint32 gasPerMinute = 200;
        SUBSIDY.subsidize{value: 1 ether}(address(bridge), criteria, gasPerMinute);

        SUBSIDY.registerBeneficiary(BENEFICIARY);
    }

    function testInvalidCaller(address _callerAddress) public {
        vm.assume(_callerAddress != rollupProcessor);
        // Use HEVM cheatcode to call from a different address than is address(this)
        vm.prank(_callerAddress);
        vm.expectRevert(ErrorLib.InvalidCaller.selector);
        bridge.convert(emptyAsset, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testInvalidInputAssetType() public {
        vm.expectRevert(ErrorLib.InvalidInputA.selector);
        bridge.convert(emptyAsset, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testInvalidOutputAssetType() public {
        AztecTypes.AztecAsset memory inputAssetA = AztecTypes.AztecAsset({
            id: 0,
            erc20Address: address(0),
            assetType: AztecTypes.AztecAssetType.ETH
        });
        vm.expectRevert(ErrorLib.InvalidOutputA.selector);
        bridge.convert(inputAssetA, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testExampleBridgeUnitTestFixed() public {
        testEthDonation(10 ether);
    }

    // @notice The purpose of this test is to directly test convert functionality of the bridge.
    // @dev In order to avoid overflows we set _depositAmount to be uint96 instead of uint256.
//     function testEthDonation1(uint96 _ethAmount) public {
//         vm.warp(block.timestamp + 1 days);
//         uint256 _project = 1;

//         // Define an input asset
//         AztecTypes.AztecAsset memory inputAssetA = AztecTypes.AztecAsset({
//             id: 0,
//             erc20Address: address(0),
//             assetType: AztecTypes.AztecAssetType.ETH
//         });


//         uint64 _auxData = 1 << 63;
//         _auxData = _auxData | uint64(0) << 32;
//         _auxData = _auxData | uint64(1);

//         // Rollup processor transfers ERC20 tokens to the bridge before calling convert. Since we are calling
//         // bridge.convert(...) function directly we have to transfer the funds in the test on our own. In this case
//         // we'll solve it by directly minting the _depositAmount of Dai to the bridge.
//         deal(address(this), _ethAmount);

//         // Store dai balance before interaction to be able to verify the balance after interaction is correct
//         //uint256 daiBalanceBefore = IERC20(DAI).balanceOf(rollupProcessor);

//         (uint256 outputValueA, uint256 outputValueB, bool isAsync) = bridge.convert{value: _ethAmount}(
//             inputAssetA, // _inputAssetA - definition of an input asset
//             emptyAsset, // _inputAssetB - not used so can be left empty
//             emptyAsset, // _outputAssetA - in this example equal to input asset
//             emptyAsset, // _outputAssetB - not used so can be left empty
//             _ethAmount, // _totalInputValue - an amount of input asset A sent to the bridge
//             0, // _interactionNonce
//             _auxData, // _auxData - not used in the example bridge
//             BENEFICIARY // _rollupBeneficiary - address, the subsidy will be sent to
//         );

//         // Now we transfer the funds back from the bridge to the rollup processor
//         // In this case input asset equals output asset so I only work with the input asset definition
//         // Basically in all the real world use-cases output assets would differ from input assets
//         //IERC20(inputAssetA.erc20Address).transferFrom(address(bridge), rollupProcessor, outputValueA);

//         //assertEq(outputValueA, _ethAmount, "Output value A doesn't equal deposit amount");
//         assertEq(outputValueA, 0, "Output value A is not 0");
//         // assertTrue(!isAsync, "Bridge is incorrectly in an async mode");
// // 
//         // uint256 daiBalanceAfter = IERC20(DAI).balanceOf(rollupProcessor);
// // 
//         // assertEq(daiBalanceAfter - daiBalanceBefore, _depositAmount, "Balances must match");
// // 
//         // SUBSIDY.withdraw(BENEFICIARY);
//         // assertGt(BENEFICIARY.balance, 0, "Subsidy was not claimed");
//     }


    function testEthDonation(uint96 _ethAmount) public {
        vm.warp(block.timestamp + 1 days);
        uint256 _projectId = 1;

        // Define an input asset
        AztecTypes.AztecAsset memory inputAssetA = AztecTypes.AztecAsset({
            id: 0,
            erc20Address: address(0),
            assetType: AztecTypes.AztecAssetType.ETH
        });

        // Action is pay
        uint64 _auxData = 1 << 63;
        // Min price is 0, since this is a donation
        _auxData = _auxData | uint64(0) << 32;
        // Projecy ID is 1
        _auxData = _auxData | uint64(_projectId);

        // Give this contract the ETH for the donation
        deal(address(this), _ethAmount);

        vm.expectEmit(true, true, false, true);
        emit AddToBalance(
            _projectId,
            _ethAmount,
            0,
            "Powered by Aztec!",
            bytes(''),
            address(bridge)
        );

        (uint256 outputValueA, uint256 outputValueB, bool isAsync) = bridge.convert{value: _ethAmount}(
            inputAssetA, // _inputAssetA - definition of an input asset
            emptyAsset, // _inputAssetB - not used so can be left empty
            emptyAsset, // _outputAssetA - in this example equal to input asset
            emptyAsset, // _outputAssetB - not used so can be left empty
            _ethAmount, // _totalInputValue - an amount of input asset A sent to the bridge
            0, // _interactionNonce
            _auxData, // _auxData - not used in the example bridge
            BENEFICIARY // _rollupBeneficiary - address, the subsidy will be sent to
        );

        // There should be no tokens returning since this was a pure donation
        assertEq(outputValueA, 0, "Output value A is not 0");
    }


    event AddToBalance(
        uint256 indexed projectId,
        uint256 amount,
        uint256 refundedFees,
        string memo,
        bytes metadata,
        address caller
    );
}
