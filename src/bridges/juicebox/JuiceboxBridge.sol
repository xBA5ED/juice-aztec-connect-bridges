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

    // TODO: Divide these more effectiently (more to price, less to operation)
    uint64 public constant OPERATION_BIT_LENGTH = 6;
    uint64 public constant PROJECT_ID_BIT_LENGTH = 32;
    uint64 public constant PRICE_BIT_LENGTH = 26;
    uint64 public constant EXPONENT_BIT_LENGTH = 5;
    
    // Binary number 0000000000000000000000000000000011111111111111111111111111111111 (last 32 bits)
    uint64 public constant PROJECT_ID_MASK = 0xFFFFFFFF;
    // Binary number 0000000000000000000000000000000000000011111111111111111111111111 (last 26 bits)
    uint64 public constant PRICE_MASK = 0x3FFFFFF;
    // Binary number 0000000000000000000000000000000000000000000000000000000000011111 (last 5 bits)
    uint64 public constant EXPONENT_MASK = 0x1F;

    // The directory that the bridge uses
    IJBDirectory directory = IJBDirectory(0x65572FB928b46f9aDB7cfe5A4c41226F636161ea);
    IJBTokenStore tokenstore = IJBTokenStore(0x6FA996581D7edaABE62C15eaE19fEeD4F1DdDfE7);

    enum BridgeOperations {
        DONATE,
        PAY,
        REDEEM
    }

    error InvalidOperation();
    error InsufficientAmountOut();
    error Overflow();

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
        // Decode the auxData to the fields we need
        (
            BridgeOperations _operation,
            uint256 _projectId,
            uint256 _minPrice
        ) = decodeAuxData(_auxData);

        // If the operation type is Donate then there should be no output token
        if ( _operation == BridgeOperations.DONATE && (_outputAssetA.assetType != AztecTypes.AztecAssetType.NOT_USED || _minPrice != 0))
            revert ErrorLib.InvalidOutputA(); 

        // Verify the input asset type and convert Aztec ETH address to Juicebox ETH address
        address _inToken;
        if (_inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20) {
            _inToken = _inputAssetA.erc20Address;
        } else if (_inputAssetA.assetType == AztecTypes.AztecAssetType.ETH) {
            _inToken = JBTokens.ETH;
        } else {
            revert ErrorLib.InvalidInputA();
        }

        // Verify the output asset type and convert Aztec ETH address to Juicebox ETH address
        address _outToken;
        if (_outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20) {
            _outToken = _outputAssetA.erc20Address;
        } else if (_outputAssetA.assetType == AztecTypes.AztecAssetType.ETH) {
            _outToken = JBTokens.ETH;
        } else if (_outputAssetA.assetType == AztecTypes.AztecAssetType.NOT_USED && _operation == BridgeOperations.DONATE ) {
            // NOT_USED is only allowed with donations, if NOT_USED is set and this is not a donation we revert
        } else {
            revert ErrorLib.InvalidOutputA();
        }

        // Calculate the minOutAmount if needed and perform the operation
        uint256 _amountOutMinimum = _outToken != address(0) ? (_totalInputValue * _minPrice) / 10**_getTokenDecimals(_outToken) : 0;
        if (_operation == BridgeOperations.PAY) {
            outputValueA = performPay(
                _projectId,
                _totalInputValue,
                _inToken,
                _amountOutMinimum
            );

        } else if (_operation == BridgeOperations.DONATE) {
             performDonation(
                 _projectId,
                 _totalInputValue,
                 _inToken
            );
            
        } else if (_operation == BridgeOperations.REDEEM){
            // Verify that the projectId uses the inputAsset as their projectToken
            require(address(tokenstore.tokenOf(_projectId)) == _inToken, "This is not the project's token");

            outputValueA = performRedeem(
                _projectId,
                _totalInputValue,
                _outToken,
                _amountOutMinimum
            );

        }else{
            revert InvalidOperation();
        }

        // If this was not a pure donation then we have to forward the tokens
        if (_operation != BridgeOperations.DONATE) {

            if (_outToken == JBTokens.ETH) {
                IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(_interactionNonce);
            } else {
                IERC20Metadata _token = IERC20Metadata(_outToken);

                // Approve rollup processor to output
                _token.approve(ROLLUP_PROCESSOR, outputValueA);
            }
        }

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
        address _token,
        uint256 _amountOutMinimum
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
            _amountOutMinimum,
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
        address _token,
        uint256 _amountOutMinimum
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
            _amountOutMinimum,
            payable(this),
            "Powered by Aztec!",
            bytes("")
        );
    }

    /**
     * @notice encodes the needed data to a uint64 for compatibility with Aztec
     */
    function encodeAuxData(
        BridgeOperations _operation,
        uint32 _projectId,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external view returns (uint64 auxData){
        // Calc the min price, unless operation is donate then minPrice is always 0
        uint256 _minPrice = _operation != BridgeOperations.DONATE ? _computeEncodedMinPrice(
            _amountIn,
            _minAmountOut,
            _getTokenDecimals(_tokenIn)
        ) : 0;

        auxData = uint64(_operation);
        auxData = auxData << PROJECT_ID_BIT_LENGTH | _projectId;
        auxData = auxData << PRICE_BIT_LENGTH | uint64(_minPrice);
    }


    /**
     * Decodes the AUX data into the needed data for Juicebox
     * @param _auxData uint64 containing encoded data
     * @return _operation the bridge operation that the user(s) request
     * @return _projectId the project to perform the operation to
     * @return _minPrice the minimum price per token the user(s) want to receive
     */
    function decodeAuxData(
        uint64 _auxData
    ) public pure returns (
        BridgeOperations _operation,
        uint32 _projectId,
        uint256 _minPrice
    ) {
        _minPrice = _decodeMinPrice(_auxData & PRICE_MASK);
        _projectId = uint32((_auxData >> PRICE_BIT_LENGTH) & PROJECT_ID_MASK);
        _operation = BridgeOperations(_auxData >> (PRICE_BIT_LENGTH + PROJECT_ID_BIT_LENGTH));
    }
    
    /**
     * From UniswapBridge
     * 
     * @notice A function which converts minimum price in a floating point format to integer.
     * @param _encodedMinPrice - Encoded minimum price (in the last 26 bits of uint256)
     * @return minPrice - Minimum acceptable price represented as an integer
     */
    function _decodeMinPrice(uint256 _encodedMinPrice) internal pure returns (uint256 minPrice) {
        // 21 bits significand, 5 bits exponent
        uint256 significand = _encodedMinPrice >> 5;
        uint256 exponent = _encodedMinPrice & EXPONENT_MASK;
        minPrice = significand * 10**exponent;
    }

    /**
     * From UniswapBridge
     * 
     * @notice A function which computes min price and encodes it in the format used in this bridge.
     * @param _amountIn - Amount of tokenIn to swap
     * @param _minAmountOut - Amount of tokenOut to receive
     * @param _tokenInDecimals - Number of decimals of tokenIn
     * @return encodedMinPrice - Min acceptable encoded in a format used in this bridge.
     * @dev This function is not optimized and is expected to be used on frontend and in tests.
     * @dev Reverts when min price is bigger than max encodeable value.
     */
    function _computeEncodedMinPrice(
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _tokenInDecimals
    ) internal pure returns (uint256 encodedMinPrice) {
        uint256 minPrice = (_minAmountOut * 10**_tokenInDecimals) / _amountIn;
        // 2097151 = 2**21 - 1 --> this number and its multiples of 10 can be encoded without precision loss
        if (minPrice <= 2097151) {
            // minPrice is smaller than the boundary of significand --> significand = _x, exponent = 0
            encodedMinPrice = minPrice << 5;
        } else {
            uint256 exponent = 0;
            while (minPrice > 2097151) {
                minPrice /= 10;
                ++exponent;
                // 31 = 2**5 - 1 --> max exponent
                if (exponent > 31) revert Overflow();
            }
            encodedMinPrice = (minPrice << 5) + exponent;
        }
    }

    /**
     * @notice attempts to get the decimals from a token, defaults to 18 if we can't fetch the token decimals
     * @param _token the token to get the decimals for
     * @return decimals of the token (or 18 as default)
     */
    function _getTokenDecimals(address _token) internal view returns(uint8) {
        // ETH has 18 decimals
        if (_token == JBTokens.ETH) return 18;

        try IERC20Metadata(_token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch (bytes memory) {
            // if the try failed we default to using 18
            return 18;
        }
    }
}
