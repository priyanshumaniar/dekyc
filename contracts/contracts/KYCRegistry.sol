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
        uint32 version; // incremented on every submitKYC; 0 = never submitted
        bool exists; // whether this user has ever submitted
    }

    /// @dev user => their KYC record
    mapping(address => KYCRecord) private _records;

    /// @dev user => verifier => unix timestamp at which access expires (0 = none)
    mapping(address => mapping(address => uint256)) private _accessExpiry;

    /// @dev user => verifier => the record version the grant was issued against.
    ///
    ///      Consent is given for a SPECIFIC bundle. Without this, `submitKYC`
    ///      would silently re-point every outstanding grant at the new bundle:
    ///      a user who granted a bank access to their Aadhaar+PAN, then later
    ///      re-uploaded a bundle that also contained a passport, would be
    ///      exposing the passport to that bank with no new consent step and no
    ///      event to notice. Binding the grant to the version means a re-upload
    ///      invalidates outstanding grants and the user must deliberately
    ///      re-grant against the new bundle.
    mapping(address => mapping(address => uint32)) private _grantVersion;

    /// @dev user => the DISTINCT verifiers they have ever granted.
    ///
    ///      A Solidity mapping cannot be enumerated, so without this list
    ///      "who can see my documents?" is unanswerable from contract state —
    ///      the client would have to replay `AccessGranted` logs (which needs an
    ///      archive-capable RPC; free tiers cap `eth_getLogs` to a handful of
    ///      blocks) or keep its own copy on the device, which is lost the moment
    ///      the user clears storage or switches machine.
    ///
    ///      Unbounded growth is safe HERE, unlike the soulbound token's issuer
    ///      list: `grantAccess` is `msg.sender`-scoped, so only the user can
    ///      append to their own list. There is no third party to spam it.
    ///      [forgetVerifier] lets them prune it, and [grantsOf] is paginated.
    mapping(address => address[]) private _verifierList;

    /// @dev user => verifier => 1-based index into `_verifierList`. 0 = absent.
    mapping(address => mapping(address => uint256)) private _verifierIndex;

    event KYCSubmitted(
        address indexed user,
        string cid,
        bytes32 docTypeHash,
        uint256 submittedAt,
        uint32 version
    );
    event AccessGranted(
        address indexed user,
        address indexed verifier,
        uint256 expiresAt,
        uint32 version
    );
    event AccessRevoked(address indexed user, address indexed verifier);
    event VerifierForgotten(address indexed user, address indexed verifier);

    /// A (verifier, grant) pair as returned by [grantsOf].
    struct GrantInfo {
        address verifier;
        uint256 expiresAt; // 0 = revoked / never granted
        uint32 grantedVersion; // record version the grant was issued against
        bool live; // mirrors hasAccess: unexpired AND version-current
    }

    error EmptyCID();
    error NoKYCRecord(address user);
    error NotAuthorized(address user, address caller);
    error InvalidExpiry(uint256 expiresAt);
    error ZeroVerifier();
    error SelfGrant();
    error NotListed(address verifier);
    error GrantStillLive(address verifier);
    error BadRange(uint256 start, uint256 end);

    constructor() Ownable(msg.sender) {}

    /// @notice Store or update the caller's KYC pointer.
    /// @param cid IPFS CID of the encrypted bundle (must be non-empty).
    /// @param docTypeHash hash describing the included document types.
    /// @dev Bumping `version` INVALIDATES every outstanding grant on this
    ///      record — see `_grantVersion`. Verifiers must be re-granted against
    ///      the new bundle. The new version is in the event so indexers can
    ///      show which grants just lapsed.
    function submitKYC(string calldata cid, bytes32 docTypeHash) external {
        if (bytes(cid).length == 0) revert EmptyCID();
        uint32 nextVersion = _records[msg.sender].version + 1;
        _records[msg.sender] = KYCRecord({
            cid: cid,
            docTypeHash: docTypeHash,
            submittedAt: block.timestamp,
            version: nextVersion,
            exists: true
        });
        emit KYCSubmitted(
            msg.sender,
            cid,
            docTypeHash,
            block.timestamp,
            nextVersion
        );
    }

    /// @notice Grant `verifier` read access to the caller's KYC until `expiresAt`.
    /// @param verifier the verifier's wallet address.
    /// @param expiresAt unix timestamp after which access lapses (must be future).
    /// @dev The grant is pinned to the CURRENT record version, so it covers the
    ///      bundle the user can see right now and nothing they upload later.
    function grantAccess(address verifier, uint256 expiresAt) external {
        if (verifier == address(0)) revert ZeroVerifier();
        if (verifier == msg.sender) revert SelfGrant();
        if (expiresAt <= block.timestamp) revert InvalidExpiry(expiresAt);
        uint32 version = _records[msg.sender].version;
        if (!_records[msg.sender].exists) revert NoKYCRecord(msg.sender);
        _accessExpiry[msg.sender][verifier] = expiresAt;
        _grantVersion[msg.sender][verifier] = version;

        // Record the verifier once, so the user can enumerate their own guest
        // list later. Costs an extra SSTORE pair on the FIRST grant to a given
        // verifier only; re-granting or renewing is unchanged.
        if (_verifierIndex[msg.sender][verifier] == 0) {
            _verifierList[msg.sender].push(verifier);
            _verifierIndex[msg.sender][verifier] =
                _verifierList[msg.sender].length; // 1-based
        }

        emit AccessGranted(msg.sender, verifier, expiresAt, version);
    }

    /// @notice Drop `verifier` from the caller's guest list entirely.
    /// @dev    Housekeeping only — it does NOT revoke. Refuses while the grant
    ///         is still live, so "tidy up the list" can never be mistaken for
    ///         "cut off their access": revoke first, then forget.
    function forgetVerifier(address verifier) external {
        uint256 idx = _verifierIndex[msg.sender][verifier];
        if (idx == 0) revert NotListed(verifier);
        if (hasAccess(msg.sender, verifier)) revert GrantStillLive(verifier);

        address[] storage list = _verifierList[msg.sender];
        uint256 lastPos = list.length;
        if (idx != lastPos) {
            // Swap-and-pop: move the tail entry into the freed slot and fix its
            // index, so removal stays O(1) instead of shifting the array.
            address moved = list[lastPos - 1];
            list[idx - 1] = moved;
            _verifierIndex[msg.sender][moved] = idx;
        }
        list.pop();
        delete _verifierIndex[msg.sender][verifier];
        delete _accessExpiry[msg.sender][verifier];
        delete _grantVersion[msg.sender][verifier];

        emit VerifierForgotten(msg.sender, verifier);
    }

    /// @notice Revoke `verifier`'s access to the caller's KYC immediately.
    /// @dev    Only writes + emits when a grant actually exists, so off-chain
    ///         indexers never see a spurious AccessRevoked for a pair that was
    ///         never granted.
    function revokeAccess(address verifier) external {
        if (verifier == address(0)) revert ZeroVerifier();
        if (_accessExpiry[msg.sender][verifier] == 0) return;
        _accessExpiry[msg.sender][verifier] = 0;
        delete _grantVersion[msg.sender][verifier];
        emit AccessRevoked(msg.sender, verifier);
    }

    /// @notice Whether `verifier` may currently read `user`'s KYC.
    /// @dev    A user always has access to their own record.
    /// @dev    Expiry is EXCLUSIVE: at `block.timestamp == expiresAt` the grant
    ///         has already lapsed. This matches `grantAccess`, which rejects
    ///         `expiresAt <= block.timestamp`, and `KYCSoulboundToken.isValid`,
    ///         which also uses a strict `>`. Both halves of the product
    ///         therefore agree on the boundary second.
    /// @dev Two conditions, both required: the grant is unexpired AND it was
    ///      issued against the record version that is current now. A re-upload
    ///      bumps the version and therefore lapses the grant.
    function hasAccess(
        address user,
        address verifier
    ) public view returns (bool) {
        if (verifier == user) return true;
        if (_accessExpiry[user][verifier] <= block.timestamp) return false;
        return _grantVersion[user][verifier] == _records[user].version;
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

    /// @notice How many DISTINCT verifiers `user` has ever granted.
    /// @dev    The page bound for [grantsOf].
    function verifierCount(address user) external view returns (uint256) {
        return _verifierList[user].length;
    }

    /// @notice The caller's guest list over the window `[start, end)`, with
    ///         each entry's live status resolved.
    ///
    /// @dev    One call replaces the 3-per-verifier round trip
    ///         (accessExpiry + grantVersion + hasAccess) the client would
    ///         otherwise need, and makes the guest list readable from any
    ///         device with no indexer, backend or local storage.
    ///
    ///         `end` is clamped to the list length, so passing a large `end` is
    ///         safe; reverts only if `start > end`.
    ///
    ///         PRIVACY: this is public, like the `AccessGranted` events it
    ///         mirrors. The chain already reveals which verifiers a user
    ///         granted — this exposes nothing new, it only makes the user's own
    ///         list as easy for them to read as it already is for everyone
    ///         else.
    function grantsOf(
        address user,
        uint256 start,
        uint256 end
    ) external view returns (GrantInfo[] memory page) {
        address[] storage list = _verifierList[user];
        uint256 len = list.length;
        if (end > len) end = len;
        if (start > end) revert BadRange(start, end);

        page = new GrantInfo[](end - start);
        for (uint256 i = start; i < end; i++) {
            address v = list[i];
            page[i - start] = GrantInfo({
                verifier: v,
                expiresAt: _accessExpiry[user][v],
                grantedVersion: _grantVersion[user][v],
                live: hasAccess(user, v)
            });
        }
    }

    /// @notice Whether `user` has ever submitted a KYC record.
    function hasRecord(address user) external view returns (bool) {
        return _records[user].exists;
    }

    /// @notice How many times `user` has submitted. 0 = never.
    /// @dev    Public metadata: it reveals the number of re-uploads, not their
    ///         contents. Clients compare it against [grantVersion] to explain
    ///         *why* a grant lapsed ("you re-uploaded since granting").
    function recordVersion(address user) external view returns (uint32) {
        return _records[user].version;
    }

    /// @notice The record version a (user, verifier) grant was issued against.
    ///         0 = no grant. Stale when it differs from [recordVersion].
    function grantVersion(
        address user,
        address verifier
    ) external view returns (uint32) {
        return _grantVersion[user][verifier];
    }
}
