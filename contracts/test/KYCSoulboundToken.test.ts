import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { KYCSoulboundToken } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const ONE_YEAR = 365 * 24 * 60 * 60;
const URI = "ipfs://attestation-metadata";
// ERC-5192 interface id (selector of locked(uint256)).
const ERC5192_ID = "0xb45a3c0e";

describe("KYCSoulboundToken", () => {
  let sbt: KYCSoulboundToken;
  let issuer: HardhatEthersSigner;
  let issuer2: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  beforeEach(async () => {
    [issuer, issuer2, user, other] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("KYCSoulboundToken");
    sbt = (await Factory.deploy()) as unknown as KYCSoulboundToken;
    await sbt.waitForDeployment();
  });

  async function attest(
    from = issuer,
    subject = user,
    ttl = ONE_YEAR
  ): Promise<bigint> {
    const expiresAt = (await time.latest()) + ttl;
    const tx = await sbt.connect(from).attest(subject.address, expiresAt, URI);
    const receipt = await tx.wait();
    // tokenId is the indexed 3rd arg of the Attested event.
    return sbt.tokenIdOf(from.address, subject.address);
  }

  it("1. mints a soulbound badge and emits Attested + Locked", async () => {
    const expiresAt = (await time.latest()) + ONE_YEAR;
    await expect(sbt.connect(issuer).attest(user.address, expiresAt, URI))
      .to.emit(sbt, "Attested")
      .withArgs(issuer.address, user.address, 1n, expiresAt, URI)
      .and.to.emit(sbt, "Locked")
      .withArgs(1n);

    expect(await sbt.ownerOf(1)).to.equal(user.address);
    expect(await sbt.balanceOf(user.address)).to.equal(1n);
  });

  it("2. isVerifiedBy is true after attest, false for others", async () => {
    await attest();
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(true);
    expect(await sbt.isVerifiedBy(issuer2.address, user.address)).to.equal(false);
  });

  it("3. tokens are soulbound — transfers revert", async () => {
    await attest();
    await expect(
      sbt
        .connect(user)
        .transferFrom(user.address, other.address, 1)
    ).to.be.revertedWithCustomError(sbt, "Soulbound");
  });

  it("4. issuer can revoke — burns the badge, isVerifiedBy false", async () => {
    await attest();
    await expect(sbt.connect(issuer).revokeAttestation(user.address))
      .to.emit(sbt, "AttestationRevoked")
      .withArgs(issuer.address, user.address, 1n);

    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(false);
    expect(await sbt.balanceOf(user.address)).to.equal(0n);
  });

  it("5. attestation lapses automatically after expiry", async () => {
    const expiresAt = (await time.latest()) + 100;
    await sbt.connect(issuer).attest(user.address, expiresAt, URI);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(true);
    await time.increaseTo(expiresAt + 1);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(false);
  });

  it("6. the same issuer cannot attest the same subject twice", async () => {
    await attest();
    const expiresAt = (await time.latest()) + ONE_YEAR;
    await expect(
      sbt.connect(issuer).attest(user.address, expiresAt, URI)
    ).to.be.revertedWithCustomError(sbt, "AlreadyAttested");
  });

  it("7. multiple issuers can each attest the same subject (reuse)", async () => {
    await attest(issuer);
    await attest(issuer2);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(true);
    expect(await sbt.isVerifiedBy(issuer2.address, user.address)).to.equal(true);
    // balanceOf == number of organizations that verified this user.
    expect(await sbt.balanceOf(user.address)).to.equal(2n);
  });

  it("8. rejects zero subject, self-attest and past expiry", async () => {
    const future = (await time.latest()) + ONE_YEAR;
    const past = (await time.latest()) - 1;
    await expect(
      sbt.connect(issuer).attest(ethers.ZeroAddress, future, URI)
    ).to.be.revertedWithCustomError(sbt, "ZeroSubject");
    await expect(
      sbt.connect(issuer).attest(issuer.address, future, URI)
    ).to.be.revertedWithCustomError(sbt, "SelfAttest");
    await expect(
      sbt.connect(issuer).attest(user.address, past, URI)
    ).to.be.revertedWithCustomError(sbt, "InvalidExpiry");
  });

  it("9. reports locked() and supports the ERC-5192 interface", async () => {
    await attest();
    expect(await sbt.locked(1)).to.equal(true);
    expect(await sbt.supportsInterface(ERC5192_ID)).to.equal(true);
    // ERC-721 interface id still supported.
    expect(await sbt.supportsInterface("0x80ac58cd")).to.equal(true);
  });

  it("10. exposes attestation data and tokenURI", async () => {
    await attest();
    const a = await sbt.attestation(1);
    expect(a.issuer).to.equal(issuer.address);
    expect(a.subject).to.equal(user.address);
    expect(a.revoked).to.equal(false);
    expect(await sbt.tokenURI(1)).to.equal(URI);
  });

  it("11. validBadgeCount counts only unrevoked, unexpired badges", async () => {
    expect(await sbt.validBadgeCount(user.address)).to.equal(0n);

    // Two distinct issuers attest → two valid badges.
    await attest(issuer);
    await attest(issuer2);
    expect(await sbt.validBadgeCount(user.address)).to.equal(2n);

    // Revoke one → one valid badge, and balanceOf agrees (burned).
    await sbt.connect(issuer).revokeAttestation(user.address);
    expect(await sbt.validBadgeCount(user.address)).to.equal(1n);
    expect(await sbt.balanceOf(user.address)).to.equal(1n);
  });

  it("12. expired badges drop out of validBadgeCount but linger in balanceOf",
    async () => {
    // A short-lived badge plus a long-lived one.
    const shortExpiry = (await time.latest()) + 100;
    await sbt.connect(issuer).attest(user.address, shortExpiry, URI);
    await attest(issuer2, user, ONE_YEAR);
    expect(await sbt.validBadgeCount(user.address)).to.equal(2n);

    // Time passes: the short one expires. It is NOT burned, so balanceOf
    // still shows 2, but validBadgeCount correctly drops to 1.
    await time.increaseTo(shortExpiry + 1);
    expect(await sbt.balanceOf(user.address)).to.equal(2n);
    expect(await sbt.validBadgeCount(user.address)).to.equal(1n);
  });

  it("13. re-attesting after revoke does not double-count", async () => {
    await attest(issuer);
    await sbt.connect(issuer).revokeAttestation(user.address);
    // Same issuer attests again after revoke — allowed, fresh token.
    await attest(issuer);
    expect(await sbt.validBadgeCount(user.address)).to.equal(1n);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(true);
  });

  it("14. an issuer CAN renew a naturally-expired badge (no revoke first)", async () => {
    // Regression guard. Expiry does not burn, so `_tokenOf` still holds the
    // dead tokenId. A naive `!= 0` duplicate guard would make AlreadyAttested
    // permanent and block the normal renewal path for the 365-day badges the
    // app mints — forcing the issuer to emit a misleading AttestationRevoked
    // just to renew.
    const shortExpiry = (await time.latest()) + 100;
    await sbt.connect(issuer).attest(user.address, shortExpiry, URI);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(true);

    await time.increaseTo(shortExpiry + 1);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(false);
    expect(await sbt.validBadgeCount(user.address)).to.equal(0n);

    // Renew directly — this reverted with AlreadyAttested before the fix.
    const newExpiry = (await time.latest()) + ONE_YEAR;
    await expect(sbt.connect(issuer).attest(user.address, newExpiry, URI))
      .to.emit(sbt, "Attested")
      .withArgs(issuer.address, user.address, 2n, newExpiry, URI);

    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(true);
    // The stale badge was recycled, not stacked: exactly one badge, one token.
    expect(await sbt.validBadgeCount(user.address)).to.equal(1n);
    expect(await sbt.balanceOf(user.address)).to.equal(1n);
    expect(await sbt.tokenIdOf(issuer.address, user.address)).to.equal(2n);
  });

  it("15. a STILL-VALID badge still blocks a duplicate attest", async () => {
    // The renewal path must not weaken the duplicate guard.
    await attest(issuer);
    const later = (await time.latest()) + ONE_YEAR;
    await expect(
      sbt.connect(issuer).attest(user.address, later, URI)
    ).to.be.revertedWithCustomError(sbt, "AlreadyAttested");
  });

  it("16. badge validity is EXCLUSIVE at expiresAt (matches KYCRegistry)", async () => {
    const expiresAt = (await time.latest()) + 1000;
    await sbt.connect(issuer).attest(user.address, expiresAt, URI);

    await time.increaseTo(expiresAt - 1);
    expect(await sbt.isValid(1)).to.equal(true);
    expect(await sbt.validBadgeCount(user.address)).to.equal(1n);

    await time.increaseTo(expiresAt);
    expect(await sbt.isValid(1)).to.equal(false);
    expect(await sbt.isVerifiedBy(issuer.address, user.address)).to.equal(false);
    expect(await sbt.validBadgeCount(user.address)).to.equal(0n);
  });

  it("17. approve / setApprovalForAll revert — a locked token grants no authority",
    async () => {
    await attest();
    // Blocking _update alone is not enough: without these overrides a
    // marketplace reads getApproved() and lists a badge that can never fill.
    await expect(
      sbt.connect(user).approve(other.address, 1)
    ).to.be.revertedWithCustomError(sbt, "Soulbound");
    await expect(
      sbt.connect(user).setApprovalForAll(other.address, true)
    ).to.be.revertedWithCustomError(sbt, "Soulbound");

    expect(await sbt.getApproved(1)).to.equal(ethers.ZeroAddress);
    expect(await sbt.isApprovedForAll(user.address, other.address)).to.equal(
      false
    );
  });

  it("18. NoAttestation and UnknownToken are reachable", async () => {
    await expect(sbt.connect(issuer).revokeAttestation(other.address))
      .to.be.revertedWithCustomError(sbt, "NoAttestation")
      .withArgs(issuer.address, other.address);

    await expect(sbt.attestation(999))
      .to.be.revertedWithCustomError(sbt, "UnknownToken")
      .withArgs(999n);
    await expect(sbt.locked(999))
      .to.be.revertedWithCustomError(sbt, "UnknownToken")
      .withArgs(999n);
  });

  it("19. after revoke the attestation record survives but the token is gone",
    async () => {
    await attest();
    await sbt.connect(issuer).revokeAttestation(user.address);

    // Historical record is retained for auditability...
    const a = await sbt.attestation(1);
    expect(a.revoked).to.equal(true);
    expect(a.issuer).to.equal(issuer.address);
    // ...but the ERC-721 token itself was burned.
    await expect(sbt.locked(1))
      .to.be.revertedWithCustomError(sbt, "UnknownToken")
      .withArgs(1n);
    await expect(sbt.tokenURI(1)).to.be.revertedWithCustomError(
      sbt,
      "ERC721NonexistentToken"
    );
  });

  it("20. issuer list can be paged: subjectIssuerCount + validBadgeCountRange",
    async () => {
    await attest(issuer);
    await attest(issuer2);
    expect(await sbt.subjectIssuerCount(user.address)).to.equal(2n);

    // Paging the whole range agrees with the unbounded convenience call.
    expect(await sbt.validBadgeCountRange(user.address, 0, 2)).to.equal(2n);
    expect(await sbt.validBadgeCountRange(user.address, 0, 1)).to.equal(1n);
    expect(await sbt.validBadgeCountRange(user.address, 1, 2)).to.equal(1n);
    expect(await sbt.validBadgeCountRange(user.address, 2, 2)).to.equal(0n);

    // `end` past the list length is clamped, not an error.
    expect(await sbt.validBadgeCountRange(user.address, 0, 999)).to.equal(2n);
    // An inverted window is.
    await expect(
      sbt.validBadgeCountRange(user.address, 2, 1)
    ).to.be.revertedWithCustomError(sbt, "BadRange");
  });
});
