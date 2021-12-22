//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "./Bridge.sol";

contract TollBridge is Bridge {
	using ECDSAUpgradeable for bytes32;
	using ECDSAUpgradeable for bytes;

	// Fees that have been paid and can be withdrawn from this contract
	mapping (address => uint256) public pendingFees;

	// Address that can sign fee hashes
	// In the future we will change this to a ERC-20 token contract
	// and anyone who holds a token will be allowed to sign fee hashes
	// Could possibly also have this address be a contract that signs the hashes
	address public feeVerifier;

	function initialize(address _controller, address _verifier) public virtual initializer {
      feeVerifier = _verifier;
		Bridge.__init_bridge(_controller);
	}

	function setFeeVerifier(address _newVerifier) external onlyOwner {
		feeVerifier = _newVerifier;
	}

	/** @dev Uses a ECDSA hash to verify that the fee paid is valid
	 * The hash must contain the following data, in the following order, with each element seperated by ''
	 * Sender addr, destination network, fee token addr, fee token amount, block valid until
	 * 
	 * If `block.number` > block valid until, revert
	 */
	function verifyFee(
		bytes32 _hash,
		bytes calldata _signature,
		uint256 _destination,
      address _tokenAddress,
      bytes calldata _feeData
	) internal view {
		address feeToken;
		uint256 feeAmount;
		uint256 maxBlock;

		(feeToken, feeAmount, maxBlock) = abi.decode(_feeData, (address, uint256, uint256));

      // This is done in order from least gas cost to highest to save gas if one of the checks fail
      // Note that I'm just guessing the order of the last two. Still need to verify that

		// Verfiy fee signature is still valid (within correct block range)
		require(block.number <= maxBlock, "TollBridge: Fee validation expired");
      
		// Check that hash is signed by a valid address
		require(_hash.recover(_signature) == feeVerifier, "TollBridge: Invalid validation");

		// Verify hash matches sent data
		bytes32 computedHash = keccak256(abi.encode(
			_msgSender(),
			_destination,
			feeToken,
			feeAmount,
			maxBlock,
         _tokenAddress
		)).toEthSignedMessageHash();

		require(_hash == computedHash, "TollBridge: Hash does not match data");
	}

	/**
	 * @dev Transfers an ERC20 token to a different chain
	 * This function simply moves the caller's tokens to this contract, and emits a `TokenTransferFungible` event
	 */
	function transferFungibleWF(
		address _token,
	   uint256 _amount,
		uint256 _networkId,
		bytes calldata _feeData,
      bytes32 _hash,
      bytes calldata _signature
	) external {
      verifyFee(_hash, _signature, _networkId, _token, _feeData);

		IERC20Upgradeable(_token).transferFrom(_msgSender(), address(this), _amount);

      _payToll(_feeData);

      emit TokenTransferFungible(_msgSender(), _token, _amount, _networkId);
   }

	/**
	 * @dev Transfers an ERC721 token to a different chain
	 * This function simply moves the caller's tokens to this contract, and emits a `TokenTransferNonFungible` event
	 */
	function transferNonFungible(
		address _token,
		uint256 _tokenId,
		uint256 _networkId,
		bytes calldata _feeData,
      bytes32 _hash,
      bytes calldata _signature
	) external virtual {
		// require(networkId != chainId(), "Same chainId");
      verifyFee(_hash, _signature, _networkId, _token, _feeData);

		IERC721Upgradeable(_token).transferFrom(_msgSender(), address(this), _tokenId);

		_payToll(_feeData);

		emit TokenTransferNonFungible(_msgSender(), _token, _tokenId, _networkId);
	}

	/**
	* @dev Transfers an ERC1155 token to a different chain
	* This function simply moves the caller's tokens to this contract, and emits a `TokenTransferMixedFungible` event
	*/
	function transferMixedFungible(
		address _token,
		uint256 _tokenId,
		uint256 _amount,
		uint256 _networkId,
		bytes calldata _feeData,
      bytes32 _hash,
      bytes calldata _signature
	) external virtual {
		// require(networkId != chainId(), "Same chainId");
      verifyFee(_hash, _signature, _networkId, _token, _feeData);

		IERC1155Upgradeable(_token).safeTransferFrom(_msgSender(), address(this), _tokenId, _amount, toBytes(0));

		_payToll(_feeData);

		emit TokenTransferMixedFungible(_msgSender(), _token, _tokenId, _amount, _networkId);
	}

	function withdrawalFees(address _token, uint256 _amount) external virtual onlyController {
		require(pendingFees[_token] >= _amount, "Insufficient funds");
		pendingFees[_token] -= _amount;
		IERC20Upgradeable(_token).transfer(_msgSender(), _amount);
	}

	/**
	* @dev Pull the amount of `tollToken` equal to `_fee` from the user's account to pay the bridge toll
	*/
	function _payToll(bytes calldata _feeData) internal {
		address token;
		uint256 fee;

		(token, fee, ) = abi.decode(_feeData, (address, uint256, uint256));

		if(fee > 0) {
			pendingFees[token] += fee;
			IERC20Upgradeable(token).transferFrom(_msgSender(), address(this), fee);
		}
	}
}
