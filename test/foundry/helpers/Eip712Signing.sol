// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The digests the backend signs, in one place.
/// @dev Deliberately holds nothing but hashing, so suites that drive the protocol and suites that
///      drive a contract against mocks can share it without sharing a deployment. It mirrors
///      _domainSeparator in Fundraise and Market by hand: if either side drifts, the tests stop
///      passing, which is the point — a copy that silently agreed would be worth nothing.
abstract contract Eip712Signing {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant INVEST_TYPEHASH =
        keccak256("Invest(address investor,uint256 projectId,uint256 amount,uint256 nonce,address inviter)");
    bytes32 internal constant SELL_TYPEHASH =
        keccak256("Sell(address seller,uint256 projectId,uint256 price,uint256 positionIndex,uint256 deadline)");
    bytes32 internal constant BUY_TYPEHASH = keccak256("Buy(address buyer,uint256 saleId)");

    function _eip712(address verifyingContract, bytes32 structHash) internal view returns (bytes32) {
        return keccak256(
            bytes.concat(
                hex"1901",
                keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, verifyingContract)),
                structHash
            )
        );
    }
}
