// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title IERC5192 — Minimal Soulbound (non-transferable) token interface.
interface IERC5192 {
    /// @notice Emitted when a token is locked (soulbound).
    event Locked(uint256 tokenId);
    /// @notice Emitted when a token is unlocked (never, here).
    event Unlocked(uint256 tokenId);
    /// @notice Returns whether `tokenId` is locked. Always true in this token.
    function locked(uint256 tokenId) external view returns (bool);
}

/// @title KYCSoulboundToken
/// @notice A non-transferable ("soulbound", ERC-5192) badge that a verifier
///         mints to a user AFTER approving their KYC. It is the reusable proof
///         at the heart of self-sovereign KYC: a user verified once by a
///         trusted issuer can present this on-chain attestation to any other
///         relying party — no re-upload, no re-check.
/// @dev    Each attestation records its issuer, subject, validity window and an
///         optional metadata URI. Tokens cannot be transferred — only minted
///         (by the issuer) and burned (revoked by the issuer). Anyone may act
///         as an issuer; relying parties decide which issuers they trust by
///         reading the `issuer` field via `isVerifiedBy`.
contract KYCSoulboundToken is ERC721, IERC5192 {
    struct Attestation {
        address issuer;
        address subject;
        uint64 issuedAt;
        uint64 expiresAt;
        bool revoked;
        string uri;
    }

    uint256 private _nextId = 1;
    mapping(uint256 => Attestation) private _attestations;
    /// @dev issuer => subject => tokenId (0 = none/revoked)
    mapping(address => mapping(address => uint256)) private _tokenOf;
    /// @dev subject => the DISTINCT issuers who have ever attested to them. Used
    ///      to count valid badges without ERC721Enumerable. We track issuers
    ///      (not tokenIds) and dedup each issuer, so a revoke/re-attest/renew
    ///      loop by the SAME issuer does not grow the list.
    ///
    ///      Scope of that guarantee: it bounds the list to the number of
    ///      DISTINCT issuers — it does NOT make the list bounded outright,
    ///      because `attest` is permissionless and anyone may become a new
    ///      issuer. `validBadgeCount` is therefore O(distinct issuers) and a
    ///      determined spammer funding many addresses can push it past an
    ///      `eth_call` gas cap. Clients that must stay responsive under that
    ///      condition should page via [subjectIssuerCount] +
    ///      [validBadgeCountRange] instead of calling [validBadgeCount].
    ///      A per-subject cap is deliberately NOT used: it would let a spammer
    ///      fill the cap and lock out legitimate issuers, which is worse.
    mapping(address => address[]) private _subjectIssuers;
    mapping(address => mapping(address => bool)) private _isSubjectIssuer;

    event Attested(
        address indexed issuer,
        address indexed subject,
        uint256 indexed tokenId,
        uint64 expiresAt,
        string uri
    );
    event AttestationRevoked(
        address indexed issuer,
        address indexed subject,
        uint256 indexed tokenId
    );

    error ZeroSubject();
    error SelfAttest();
    error InvalidExpiry();
    error AlreadyAttested(address issuer, address subject);
    error NoAttestation(address issuer, address subject);
    error UnknownToken(uint256 tokenId);
    error Soulbound();
    error BadRange(uint256 start, uint256 end);

    constructor() ERC721("DeKYC Verified", "DKYC") {}

    /// @notice Issue a soulbound KYC badge to `subject`, valid until `expiresAt`.
    /// @param subject the verified user's wallet.
    /// @param expiresAt unix timestamp when the attestation lapses (future).
    /// @param uri optional metadata URI describing the attestation.
    /// @return tokenId the minted token id.
    function attest(
        address subject,
        uint64 expiresAt,
        string calldata uri
    ) external returns (uint256 tokenId) {
        if (subject == address(0)) revert ZeroSubject();
        if (subject == msg.sender) revert SelfAttest();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();

        // RENEWAL: expiry alone never clears `_tokenOf` (an expired badge is
        // not burned), so a naive `!= 0` guard would block an issuer from ever
        // re-attesting after their badge lapsed — the normal renewal path for
        // the 365-day badges this app mints. Reject only a STILL-VALID badge;
        // recycle a dead one (expired or revoked) by burning it first.
        uint256 existing = _tokenOf[msg.sender][subject];
        if (existing != 0) {
            if (isValid(existing)) revert AlreadyAttested(msg.sender, subject);
            _attestations[existing].revoked = true;
            delete _tokenOf[msg.sender][subject];
            _burn(existing);
        }

        tokenId = _nextId++;
        _attestations[tokenId] = Attestation({
            issuer: msg.sender,
            subject: subject,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            revoked: false,
            uri: uri
        });
        _tokenOf[msg.sender][subject] = tokenId;
        // Record the issuer once. Re-attesting after a revoke reuses this slot,
        // so the per-subject list cannot be inflated by repeated cycles.
        if (!_isSubjectIssuer[subject][msg.sender]) {
            _isSubjectIssuer[subject][msg.sender] = true;
            _subjectIssuers[subject].push(msg.sender);
        }

        // _mint (not _safeMint): the token is soulbound and can never be
        // transferred onward, so the ERC721 receiver-hook check buys nothing
        // and would only block contract-wallet subjects (e.g. a Safe).
        _mint(subject, tokenId);
        emit Locked(tokenId);
        emit Attested(msg.sender, subject, tokenId, expiresAt, uri);
    }

    /// @notice Revoke the caller's attestation for `subject` (burns the badge).
    function revokeAttestation(address subject) external {
        uint256 tokenId = _tokenOf[msg.sender][subject];
        if (tokenId == 0) revert NoAttestation(msg.sender, subject);
        _attestations[tokenId].revoked = true;
        delete _tokenOf[msg.sender][subject];
        _burn(tokenId);
        emit AttestationRevoked(msg.sender, subject, tokenId);
    }

    /// @notice Full attestation record for a token.
    function attestation(
        uint256 tokenId
    ) external view returns (Attestation memory) {
        Attestation storage a = _attestations[tokenId];
        if (a.issuer == address(0)) revert UnknownToken(tokenId);
        return a;
    }

    /// @notice Whether a token is currently valid (exists, unrevoked, unexpired).
    function isValid(uint256 tokenId) public view returns (bool) {
        Attestation storage a = _attestations[tokenId];
        return
            a.issuer != address(0) &&
            !a.revoked &&
            a.expiresAt > block.timestamp;
    }

    /// @notice Whether `issuer` has a currently-valid attestation for `subject`.
    function isVerifiedBy(
        address issuer,
        address subject
    ) external view returns (bool) {
        return isValid(_tokenOf[issuer][subject]);
    }

    /// @notice The (possibly revoked/expired) tokenId for an (issuer, subject).
    function tokenIdOf(
        address issuer,
        address subject
    ) external view returns (uint256) {
        return _tokenOf[issuer][subject];
    }

    /// @notice How many CURRENTLY-VALID badges `subject` holds — unrevoked AND
    ///         unexpired. Unlike `balanceOf`, expired badges are excluded
    ///         (expiry does not burn the token, so `balanceOf` over-counts).
    /// @dev    Permissionless attestation means this is a count, NOT a trust
    ///         score: anyone may mint a badge. Relying parties must check the
    ///         ISSUER of each badge (`isVerifiedBy`) against issuers they trust.
    function validBadgeCount(address subject) external view returns (uint256) {
        return _countRange(subject, 0, _subjectIssuers[subject].length);
    }

    /// @notice How many DISTINCT issuers have ever attested to `subject`.
    /// @dev    The page bound for [validBadgeCountRange]. Cheap: one SLOAD.
    function subjectIssuerCount(address subject) external view returns (uint256) {
        return _subjectIssuers[subject].length;
    }

    /// @notice [validBadgeCount] over the issuer window `[start, end)`.
    /// @dev    Lets a client page a subject with very many issuers instead of
    ///         risking an out-of-gas `eth_call` on the unbounded variant.
    ///         `end` is clamped to the list length, so passing a large `end` is
    ///         safe. Reverts if `start > end`.
    function validBadgeCountRange(
        address subject,
        uint256 start,
        uint256 end
    ) external view returns (uint256) {
        return _countRange(subject, start, end);
    }

    function _countRange(
        address subject,
        uint256 start,
        uint256 end
    ) private view returns (uint256 n) {
        address[] storage issuers = _subjectIssuers[subject];
        uint256 len = issuers.length;
        if (end > len) end = len;
        if (start > end) revert BadRange(start, end);
        for (uint256 i = start; i < end; i++) {
            uint256 tid = _tokenOf[issuers[i]][subject];
            if (tid != 0 && isValid(tid)) {
                unchecked {
                    ++n;
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // ERC-5192 soulbound behaviour
    // -------------------------------------------------------------------------

    /// @inheritdoc IERC5192
    function locked(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) revert UnknownToken(tokenId);
        return true; // always soulbound
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _attestations[tokenId].uri;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IERC5192).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @dev A locked token must never advertise transfer authority. Blocking
    ///      `_update` alone is not enough: without these overrides `approve`
    ///      and `setApprovalForAll` still SUCCEED on a soulbound badge, so
    ///      marketplaces and portfolio trackers read `getApproved` /
    ///      `isApprovedForAll` and surface the badge as listable — it only
    ///      fails later, at fill time. The EIP-5192 reference implementation
    ///      guards both for exactly this reason.
    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    /// @dev Block transfers: permit only mint (from == 0) and burn (to == 0).
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }
}
