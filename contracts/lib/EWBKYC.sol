// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title EWBKYC
 * @notice Pure KYC attestation hashing + signature recovery for
 *         EWBMintingRightsVault. Extracted to reduce parent bytecode.
 * @dev    Behavior-preserving: identical data hash domain string, identical
 *         ecrecover handling, identical revert semantics to the original
 *         inlined code. No storage — all functions are pure.
 */
library EWBKYC {
    error InvalidSignatureLength();
    error InvalidSignatureV();

    /// @dev Domain string MUST stay byte-identical to the original or every
    ///      previously-valid signature breaks. Do not "tidy" this constant.
    string internal constant DOMAIN = "EWB_HARDSCAN_KYC_V1";

    function attestationHash(
        address borrower,
        uint256 dataTimestamp,
        string calldata kycId,
        bytes32 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            DOMAIN,
            borrower,
            dataTimestamp,
            kycId,
            nonce
        ));
    }

    function recoverSigner(bytes32 dataHash, bytes memory signature)
        internal pure returns (address signer)
    {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 ethHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)
        );

        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignatureV();

        signer = ecrecover(ethHash, v, r, s);
        require(signer != address(0), "EWBKYC: zero signer");
    }

    function verify(
        address attestor,
        address borrower,
        uint256 dataTimestamp,
        string calldata kycId,
        bytes32 nonce,
        bytes memory signature
    ) internal pure returns (bool ok) {
        bytes32 h = attestationHash(borrower, dataTimestamp, kycId, nonce);
        return recoverSigner(h, signature) == attestor;
    }
}
