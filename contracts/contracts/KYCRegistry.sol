// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title KYCRegistry
/// @notice Self-sovereign KYC registry. The blockchain stores ONLY a pointer
///         (IPFS CID + doc-type hash + timestamp) to each user's encrypted KYC
///         bundle, plus a per-user access-control table. The documents
///         themselves never touch the chain; they live encrypted on IPFS.
/// @dev    Identity == the user's wallet address (msg.sender). There are NO
///         admin escape hatches: the contract owner cannot read, grant, or
///         revoke any user's data. `Ownable` is retained purely for
///         provenance/ownership metadata, not for data access.
contract KYCRegistry is Ownable {
    struct KYCRecord {
        string cid; // IPFS CID of the encrypted KYC bundle
        bytes32 docTypeHash; // hash describing which doc types are included
        uint256 submittedAt; // block timestamp of the latest submission
        bool exists; // whether this user has ever submitted
    }

    /// @dev user => their KYC record
    mapping(address => KYCRecord) private _records;

    /// @dev user => verifier => unix timestamp at which access expires (0 = none)
    mapping(address => mapping(address => uint256)) private _accessExpiry;

    event KYCSubmitted(
        address indexed user,
        string cid,
        bytes32 docTypeHash,
        uint256 submittedAt
    );
    event AccessGranted(
        address indexed user,
        address indexed verifier,
        uint256 expiresAt
    );
    event AccessRevoked(address indexed user, address indexed verifier);

    error EmptyCID();
    error NoKYCRecord(address user);
    error NotAuthorized(address user, address caller);
    error InvalidExpiry(uint256 expiresAt);
    error ZeroVerifier();
    error SelfGrant();

    constructor() Ownable(msg.sender) {}

    /// @notice Store or update the caller's KYC pointer.
    /// @param cid IPFS CID of the encrypted bundle (must be non-empty).
    /// @param docTypeHash hash describing the included document types.
    function submitKYC(string calldata cid, bytes32 docTypeHash) external {
        if (bytes(cid).length == 0) revert EmptyCID();
        _records[msg.sender] = KYCRecord({
            cid: cid,
            docTypeHash: docTypeHash,
            submittedAt: block.timestamp,
            exists: true
        });
        emit KYCSubmitted(msg.sender, cid, docTypeHash, block.timestamp);
    }

    /// @notice Grant `verifier` read access to the caller's KYC until `expiresAt`.
    /// @param verifier the verifier's wallet address.
    /// @param expiresAt unix timestamp after which access lapses (must be future).
    function grantAccess(address verifier, uint256 expiresAt) external {
        if (verifier == address(0)) revert ZeroVerifier();
        if (verifier == msg.sender) revert SelfGrant();
        if (expiresAt <= block.timestamp) revert InvalidExpiry(expiresAt);
        if (!_records[msg.sender].exists) revert NoKYCRecord(msg.sender);
        _accessExpiry[msg.sender][verifier] = expiresAt;
        emit AccessGranted(msg.sender, verifier, expiresAt);
    }

    /// @notice Revoke `verifier`'s access to the caller's KYC immediately.
    /// @dev    Only writes + emits when a grant actually exists, so off-chain
    ///         indexers never see a spurious AccessRevoked for a pair that was
    ///         never granted.
    function revokeAccess(address verifier) external {
        if (verifier == address(0)) revert ZeroVerifier();
        if (_accessExpiry[msg.sender][verifier] == 0) return;
        _accessExpiry[msg.sender][verifier] = 0;
        emit AccessRevoked(msg.sender, verifier);
    }

    /// @notice Whether `verifier` may currently read `user`'s KYC.
    /// @dev    A user always has access to their own record.
    function hasAccess(
        address user,
        address verifier
    ) public view returns (bool) {
        if (verifier == user) return true;
        uint256 expiry = _accessExpiry[user][verifier];
        return expiry != 0 && expiry >= block.timestamp;
    }

    /// @notice Read `user`'s KYC pointer. Reverts unless the caller is the user
    ///         or a verifier with unexpired access.
    function getKYC(
        address user
    ) external view returns (string memory cid, uint256 submittedAt) {
        KYCRecord storage rec = _records[user];
        if (!rec.exists) revert NoKYCRecord(user);
        if (!hasAccess(user, msg.sender)) revert NotAuthorized(user, msg.sender);
        return (rec.cid, rec.submittedAt);
    }

    /// @notice Read the doc-type hash for `user`. Same access gate as getKYC.
    function getDocTypeHash(address user) external view returns (bytes32) {
        KYCRecord storage rec = _records[user];
        if (!rec.exists) revert NoKYCRecord(user);
        if (!hasAccess(user, msg.sender)) revert NotAuthorized(user, msg.sender);
        return rec.docTypeHash;
    }

    /// @notice Raw expiry timestamp for a (user, verifier) pair. 0 = no grant.
    /// @dev    Public metadata; reveals nothing about the documents.
    function accessExpiry(
        address user,
        address verifier
    ) external view returns (uint256) {
        return _accessExpiry[user][verifier];
    }

    /// @notice Whether `user` has ever submitted a KYC record.
    function hasRecord(address user) external view returns (bool) {
        return _records[user].exists;
    }
}
