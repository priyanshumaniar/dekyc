import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { KYCRegistry } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const CID_1 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
const CID_2 = "bafkreieq5jui4j25lacwomsqgjeswwl3y5zcdrresswch7hsuvn7vyrxs4";
const DOC_HASH = ethers.keccak256(
  ethers.toUtf8Bytes("aadhaar_front,aadhaar_back,pan,photo")
);
const ONE_HOUR = 60 * 60;

describe("KYCRegistry", () => {
  let registry: KYCRegistry;
  let owner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let verifier: HardhatEthersSigner;
  let verifier2: HardhatEthersSigner;
  let stranger: HardhatEthersSigner;

  beforeEach(async () => {
    [owner, user, verifier, verifier2, stranger] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("KYCRegistry");
    registry = (await Factory.deploy()) as unknown as KYCRegistry;
    await registry.waitForDeployment();
  });

  describe("submitKYC", () => {
    it("1. stores a record and emits KYCSubmitted", async () => {
      await expect(registry.connect(user).submitKYC(CID_1, DOC_HASH))
        .to.emit(registry, "KYCSubmitted")
        .withArgs(user.address, CID_1, DOC_HASH, anyTimestamp());

      expect(await registry.hasRecord(user.address)).to.equal(true);
      // The user can always read their own record.
      const [cid] = await registry.connect(user).getKYC(user.address);
      expect(cid).to.equal(CID_1);
    });

    it("2. updates an existing record (latest CID wins)", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      const firstTs = (await registry.connect(user).getKYC(user.address))[1];

      await time.increase(5);
      await registry.connect(user).submitKYC(CID_2, DOC_HASH);

      const [cid, submittedAt] = await registry
        .connect(user)
        .getKYC(user.address);
      expect(cid).to.equal(CID_2);
      expect(submittedAt).to.be.greaterThan(firstTs);
    });

    it("3. reverts on an empty CID", async () => {
      await expect(
        registry.connect(user).submitKYC("", DOC_HASH)
      ).to.be.revertedWithCustomError(registry, "EmptyCID");
    });
  });

  describe("grantAccess / hasAccess", () => {
    beforeEach(async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
    });

    it("4. grants a verifier read access and emits AccessGranted", async () => {
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await expect(registry.connect(user).grantAccess(verifier.address, expiresAt))
        .to.emit(registry, "AccessGranted")
        .withArgs(user.address, verifier.address, expiresAt);

      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        true
      );
      const [cid] = await registry.connect(verifier).getKYC(user.address);
      expect(cid).to.equal(CID_1);
    });

    it("5. supports multiple independent verifiers", async () => {
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      await registry.connect(user).grantAccess(verifier2.address, expiresAt);

      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(true);
      expect(await registry.hasAccess(user.address, verifier2.address)).to.equal(true);
      // Revoking one does not affect the other.
      await registry.connect(user).revokeAccess(verifier.address);
      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(false);
      expect(await registry.hasAccess(user.address, verifier2.address)).to.equal(true);
    });

    it("6. rejects granting before any KYC exists, self-grants, zero address and past expiry", async () => {
      const future = (await time.latest()) + ONE_HOUR;
      const past = (await time.latest()) - 1;

      // stranger has no record yet
      await expect(
        registry.connect(stranger).grantAccess(verifier.address, future)
      ).to.be.revertedWithCustomError(registry, "NoKYCRecord");

      await expect(
        registry.connect(user).grantAccess(user.address, future)
      ).to.be.revertedWithCustomError(registry, "SelfGrant");

      await expect(
        registry.connect(user).grantAccess(ethers.ZeroAddress, future)
      ).to.be.revertedWithCustomError(registry, "ZeroVerifier");

      await expect(
        registry.connect(user).grantAccess(verifier.address, past)
      ).to.be.revertedWithCustomError(registry, "InvalidExpiry");
    });
  });

  describe("revokeAccess", () => {
    it("7. revokes access and emits AccessRevoked; reads then revert", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);

      await expect(registry.connect(user).revokeAccess(verifier.address))
        .to.emit(registry, "AccessRevoked")
        .withArgs(user.address, verifier.address);

      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(false);
      await expect(
        registry.connect(verifier).getKYC(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
    });
  });

  describe("expiry", () => {
    it("8. access lapses automatically once expiresAt passes", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);

      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(true);

      await time.increaseTo(expiresAt + 1);

      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(false);
      await expect(
        registry.connect(verifier).getKYC(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
    });
  });

  describe("unauthorized reads", () => {
    it("9. a stranger cannot read another user's KYC", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      await expect(
        registry.connect(stranger).getKYC(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
    });

    it("10. reading a non-existent record reverts with NoKYCRecord", async () => {
      await expect(
        registry.connect(stranger).getKYC(stranger.address)
      ).to.be.revertedWithCustomError(registry, "NoKYCRecord");
    });

    it("11. owner has NO special access to user data (no admin escape hatch)", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      await expect(
        registry.connect(owner).getKYC(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
    });
  });
});

// Helper: hardhat-chai-matchers exposes anyValue; alias it for readability.
function anyTimestamp() {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
  return anyValue;
}
