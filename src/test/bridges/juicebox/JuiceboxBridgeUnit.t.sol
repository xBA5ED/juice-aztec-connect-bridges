// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BridgeTestBase} from "./../../aztec/base/BridgeTestBase.sol";
import {AztecTypes} from "../../../aztec/libraries/AztecTypes.sol";

// JB-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ErrorLib} from "../../../bridges/base/ErrorLib.sol";
import "../../../bridges/juicebox/JuiceboxBridge.sol";
import {IJBSingleTokenPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBSingleTokenPaymentTerminal.sol";

// @notice The purpose of this test is to directly test convert functionality of the bridge.
contract JuiceboxBridgeUnitTest is BridgeTestBase {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant BENEFICIARY = address(11);

    // The directory that the bridge uses
    IJBDirectory directory = IJBDirectory(0x65572FB928b46f9aDB7cfe5A4c41226F636161ea);
    IJBTokenStore tokenstore = IJBTokenStore(0x6FA996581D7edaABE62C15eaE19fEeD4F1DdDfE7);

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

    // function testInvalidOutputAssetType() public {
    //     AztecTypes.AztecAsset memory inputAssetA = AztecTypes.AztecAsset({
    //         id: 0,
    //         erc20Address: address(0),
    //         assetType: AztecTypes.AztecAssetType.ETH
    //     });
    //     vm.expectRevert(ErrorLib.InvalidOutputA.selector);
    //     bridge.convert(inputAssetA, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    // }


    function testEncodeDecodeAuxData(uint8 _operation_uint8, uint32 _projectId, uint120 _minPrice) public {
        // Operation only has 6 bits and not full 8
        vm.assume(_operation_uint8 < 3);
        JuiceboxBridge.BridgeOperations _operation = JuiceboxBridge.BridgeOperations(_operation_uint8);

        // Encode the data
        uint64 _encoded = bridge.encodeAuxData(
            _operation,
            _projectId,
            address(DAI),
            1 ether,
            _minPrice
        );

        // Decode the data
        (JuiceboxBridge.BridgeOperations _d_operation, uint32 _d_projectId, uint _d_minPrice) = bridge.decodeAuxData(_encoded);

        // Make sure the input and output are equal
        assertEq(
            uint8(_d_operation),
            uint8(_operation),
            "Operation was not decoded correctly"
        );

        assertEq(
            _d_projectId,
            _projectId,
            "ProjectID was not decoded correctly"
        );

        if (_operation != JuiceboxBridge.BridgeOperations.DONATE){
            // Get the difference between the input and the output
            uint256 _precisionError = _d_minPrice > _minPrice ? _d_minPrice - _minPrice : _minPrice - _d_minPrice;
            // Make sure the precision error is not more then 0.001% for a uint120
            assertLe(
                _precisionError,
                _minPrice / 100_000
            );
        }else{
            // _minPrice is always 0 when donating
            assertEq(
                _d_minPrice,
                0
            );
        }
    }

    function testDonateToJuiceboxDAO() public {
        // Test 10 ether donation to JuiceboxDAO
        testDonateToProject(10 ether);
    }

    function testDonateToProject(uint96 _amount) public {
        vm.assume(_amount > 0);
        uint8 _projectId = 1; // TODO: once more projects are configured we can fuzz test on random ones

        // Make sure we can pay this project and get a token we can pay them with
        (address _token, bool _canPay) = _getProjectPaymentToken(_projectId);
        vm.assume(_canPay);

        // Convert to Aztec asset
        AztecTypes.AztecAsset memory inputAssetA;
        if(_token == JBTokens.ETH){
            inputAssetA = AztecTypes.AztecAsset({
                id: 0,
                erc20Address: address(0),
                assetType: AztecTypes.AztecAssetType.ETH
            });

            // Give this contract the ETH for the donation
            deal(address(this), _amount);
        } else{
            inputAssetA = AztecTypes.AztecAsset({
                id: 0,
                erc20Address: _token,
                assetType: AztecTypes.AztecAssetType.ERC20
            });

            // Give this contract the ETH for the donation
            deal(_token, address(this), _amount);
        }

        uint64 _auxData = bridge.encodeAuxData(
            JuiceboxBridge.BridgeOperations.DONATE, // pay (or donate)
            _projectId,
            address(0),
            _amount,
            0
        );

        bridge.decodeAuxData(_auxData);

        vm.expectEmit(true, true, false, true);
        emit AddToBalance(
            _projectId,
            _amount,
            0,
            "Powered by Aztec!",
            bytes(''),
            address(bridge)
        );
        
        (uint256 outputValueA, uint256 outputValueB, bool isAsync) = bridge.convert{value: _token == JBTokens.ETH ? _amount : 0}(
            inputAssetA, // _inputAssetA - definition of an input asset
            emptyAsset, // _inputAssetB - not used so can be left empty
            emptyAsset, // _outputAssetA - in this example equal to input asset
            emptyAsset, // _outputAssetB - not used so can be left empty
            _amount, // _totalInputValue - an amount of input asset A sent to the bridge
            0, // _interactionNonce
            _auxData, // _auxData - not used in the example bridge
            BENEFICIARY // _rollupBeneficiary - address, the subsidy will be sent to
        );

        // There should be no tokens returning since this was a pure donation
        assertEq(outputValueA, 0, "Output value A is not 0");
    }


    // Currently there is only 1 fully configured project on V3 and that is JuiceboxDAO, we'll use this later 
    function _getProjectPaymentToken(uint32 _projectId) internal returns (address _token, bool _canPayProject){
        IJBPaymentTerminal[] memory _terminals = directory.terminalsOf(_projectId);
        if(_terminals.length == 0) return (address(0), false);

        return (IJBSingleTokenPaymentTerminal(address(_terminals[0])).token(), true);
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
