// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AztecTypes} from "../../aztec/libraries/AztecTypes.sol";
import {ErrorLib} from "../base/ErrorLib.sol";
import {BridgeBase} from "../base/BridgeBase.sol";
import {IRollupProcessor} from "../../aztec/interfaces/IRollupProcessor.sol";

import {IJBPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPaymentTerminal.sol";
import {IJBPayoutRedemptionPaymentTerminal} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol";
import {IJBDirectory} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
import {IJBTokenStore} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBTokenStore.sol";
import {JBTokens} from "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

/**
 * @title An example bridge contract.
 * @author Aztec Team
 * @notice You can use this contract to immediately get back what you've deposited.
 * @dev This bridge demonstrates the flow of assets in the convert function. This bridge simply returns what has been
 *      sent to it.
 */
contract JuiceboxBridge is BridgeBase {
    // The directory that the bridge uses
    IJBDirectory directory = IJBDirectory(0x65572FB928b46f9aDB7cfe5A4c41226F636161ea);
    IJBTokenStore tokenstore = IJBTokenStore(0x6FA996581D7edaABE62C15eaE19fEeD4F1DdDfE7);

    error InsufficientAmountOut();

    // @dev Event which is emitted when the output token doesn't implement decimals().
    event DefaultDecimalsWarning();

    // @dev Empty method which is present here in order to be able to receive ETH when unwrapping WETH.
    receive() external payable {}

    /**
     * @notice Set address of rollup processor
     * @param _rollupProcessor Address of rollup processor
     */
    constructor(address _rollupProcessor) BridgeBase(_rollupProcessor) {
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        uint256[] memory criterias = new uint256[](2);
        uint32[] memory gasUsage = new uint32[](2);
        uint32[] memory minGasPerMinute = new uint32[](2);

        criterias[0] = uint256(keccak256(abi.encodePacked(dai, dai)));
        criterias[1] = uint256(keccak256(abi.encodePacked(usdc, usdc)));

        gasUsage[0] = 72896;
        gasUsage[1] = 80249;

        minGasPerMinute[0] = 100;
        minGasPerMinute[1] = 150;

        // We set gas usage in the subsidy contract
        // We only want to incentivize the bridge when input and output token is Dai or USDC
        SUBSIDY.setGasUsageAndMinGasPerMinute(criterias, gasUsage, minGasPerMinute);
    }

    /**
     * @notice A function which returns an _totalInputValue amount of _inputAssetA
     * @param _inputAssetA - Arbitrary ERC20 token
     * @param _outputAssetA - Equal to _inputAssetA
     * @param  - Address of the contract which receives subsidy in case subsidy was set for a given
     *                             criteria
     * @return outputValueA - the amount of output asset to return
     * @dev In this case _outputAssetA equals _inputAssetA
     */
    function convert(
        AztecTypes.AztecAsset calldata _inputAssetA,
        AztecTypes.AztecAsset calldata,
        AztecTypes.AztecAsset calldata _outputAssetA,
        AztecTypes.AztecAsset calldata,
        uint256 _totalInputValue,
        uint256 _interactionNonce,
        uint64 _auxData,
        address
    )
        external
        payable
        override(BridgeBase)
        onlyRollup
        returns (
            uint256 outputValueA,
            uint256,
            bool
        )
    {
        bool _isPay = _auxData >> 63 == 1;
        uint32 _minPrice = uint32(32 >> _auxData );
        uint256 _projectId = uint32(_auxData);

        address _inToken;
        if(_inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20){
            _inToken = _inputAssetA.erc20Address;
        }else if(_inputAssetA.assetType == AztecTypes.AztecAssetType.ETH){
            _inToken = JBTokens.ETH;
        }else{
            revert ErrorLib.InvalidInputA();
        }

         address _outToken;
         if(_outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20){
            _inToken = _outputAssetA.erc20Address;
         }else if(_outputAssetA.assetType == AztecTypes.AztecAssetType.ETH){
             _outToken = JBTokens.ETH;
         }else if(_outputAssetA.assetType == AztecTypes.AztecAssetType.NOT_USED){
             // This is a pure donation and the user will not receive a token in exchange
             require(_minPrice == 0, "For donations the minPrice should be 0");
         }else{
             revert ErrorLib.InvalidOutputA();
         }

        // 1: Pay
        // 2: Redeem
        if (_isPay) {
            // Does the user expect tokens in return, or is this a pure donation
            if (_outToken != address(0)){
                outputValueA = performPay(
                    _projectId,
                    _totalInputValue,
                    _inToken
                );
            }else{
                 performDonation(
                    _projectId,
                    _totalInputValue,
                    _inToken
                );
            }
            
        } else {
            // Verify that the projectId uses the inputAsset as their projectToken
            require(address(tokenstore.tokenOf(_projectId)) == _inToken, "This is not the project's token");

            outputValueA = performRedeem(
                _projectId,
                _totalInputValue,
                _outToken
            );
        }

         //uint256 tokenInDecimals = 18;
        // try IERC20Metadata(_inputAssetA.erc20Address).decimals() returns (uint8 decimals) {
            //     tokenInDecimals = decimals;
            // } catch (bytes memory) {
            //     emit DefaultDecimalsWarning();
            // }

       
        // If this was not a pure donation then we have to forward the tokens
        if (_outToken != address(0) && outputValueA != 0) {
            if (_outToken == JBTokens.ETH) {
                IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(_interactionNonce);
            }else{
                // Approve rollup processor to output
                IERC20(_outputAssetA.erc20Address).approve(ROLLUP_PROCESSOR, outputValueA);
            }
        }else{
            // If this was a pure donation then we always return 0
            outputValueA = 0;
        }

        //uint256 amountOutMinimum = (_totalInputValue * _minPrice) / 10**tokenInDecimals;
        //if (outputValueA < amountOutMinimum) revert InsufficientAmountOut();

        // Pay out subsidy to the rollupBeneficiary
        // SUBSIDY.claimSubsidy(
        //     computeCriteria(_inputAssetA, _inputAssetB, _outputAssetA, _outputAssetB, _auxData),
        //     _rollupBeneficiary
        // );
    }

    /**
     * @notice Computes the criteria that is passed when claiming subsidy.
     * @param _inputAssetA The input asset
     * @param _outputAssetA The output asset
     * @return The criteria
     */
    function computeCriteria(
        AztecTypes.AztecAsset calldata _inputAssetA,
        AztecTypes.AztecAsset calldata,
        AztecTypes.AztecAsset calldata _outputAssetA,
        AztecTypes.AztecAsset calldata,
        uint64
    ) public view override(BridgeBase) returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_inputAssetA.erc20Address, _outputAssetA.erc20Address)));
    }

    function performPay(
        uint256 _projectId,
        uint256 _amount,
        address _token
    ) internal returns (uint256 output) {
        IJBPaymentTerminal _terminal = directory.primaryTerminalOf(_projectId, _token);

        output = _terminal.pay{value: _token == JBTokens.ETH ? _amount : 0}(
            _projectId,
            // The pay amount
            _amount,
            // if the input is ETH we have to use the Juicebox ETH address
            _token,
            address(this),
            // We let min returned tokens as 0, we'll check after we received it
            0,
            // We do prefer to receive ERC20
            true,
            // The message the UI will show
            "Powered by Aztec!",
            // No metadata is needed
            bytes("")
        );
    }

    function performDonation(
        uint256 _projectId,
        uint256 _amount,
        address _token
    ) internal {
        IJBPaymentTerminal _terminal = directory.primaryTerminalOf(_projectId, _token);

        _terminal.addToBalanceOf{value: _token == JBTokens.ETH ? _amount : 0}(
            _projectId,
            // The pay amount
            _amount,
            // if the input is ETH we have to use the Juicebox ETH address
            _token,
            // The message the UI will show
            "Powered by Aztec!",
            // No metadata is needed
            bytes("")
        );
    }

    function performRedeem(
        uint256 _projectId,
        uint256 _amount,
        address _token
    ) internal returns (uint256 output) {
        IJBPayoutRedemptionPaymentTerminal _terminal = IJBPayoutRedemptionPaymentTerminal(
            address(directory.primaryTerminalOf(_projectId, _token))
        );

        // Make sure this terminal supports redemptions
        if (!_terminal.supportsInterface(type(IJBPayoutRedemptionPaymentTerminal).interfaceId))
            revert("redemption not supported");

        output = _terminal.redeemTokensOf(
            address(this),
            _projectId,
            _amount,
            // if the output is ETH we have to use the Juicebox ETH address
            _token,
            0,
            payable(this),
            "Powered by Aztec!",
            bytes("")
        );
    }
}
