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
        .withArgs(user.address, CID_1, DOC_HASH, anyTimestamp(), 1);

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
        .withArgs(user.address, verifier.address, expiresAt, 1);

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

  describe("expiry boundary", () => {
    // The exact second a grant lapses is the thing a reviewer checks first, and
    // it is the one place an off-by-one silently widens an access window.
    it("12. is EXCLUSIVE — valid at expiresAt-1, denied at expiresAt", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);

      await time.increaseTo(expiresAt - 1);
      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        true
      );
      expect((await registry.connect(verifier).getKYC(user.address))[0]).to.equal(
        CID_1
      );

      // One second later — exactly at expiresAt — the grant is already gone.
      await time.increaseTo(expiresAt);
      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        false
      );
      await expect(
        registry.connect(verifier).getKYC(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
    });

    it("13. grantAccess is strict too — expiresAt == now is rejected", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      const now = await time.latest();
      await expect(
        registry.connect(user).grantAccess(verifier.address, now)
      ).to.be.revertedWithCustomError(registry, "InvalidExpiry");
    });
  });

  describe("revokeAccess edge cases", () => {
    it("14. revoking a never-granted pair succeeds silently (no phantom event)", async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
      // The NatSpec promises indexers never see a spurious AccessRevoked.
      await expect(
        registry.connect(user).revokeAccess(stranger.address)
      ).to.not.emit(registry, "AccessRevoked");
      expect(await registry.hasAccess(user.address, stranger.address)).to.equal(
        false
      );
    });

    it("15. revoking the zero address reverts ZeroVerifier", async () => {
      await expect(
        registry.connect(user).revokeAccess(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(registry, "ZeroVerifier");
    });
  });

  describe("getDocTypeHash / accessExpiry", () => {
    beforeEach(async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
    });

    it("16. getDocTypeHash enforces the same gate as getKYC", async () => {
      // Owner of the record can always read it.
      expect(await registry.connect(user).getDocTypeHash(user.address)).to.equal(
        DOC_HASH
      );

      // A stranger cannot — the gate is duplicated in the contract, so it gets
      // its own assertions rather than riding on getKYC's.
      await expect(
        registry.connect(stranger).getDocTypeHash(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");

      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      expect(
        await registry.connect(verifier).getDocTypeHash(user.address)
      ).to.equal(DOC_HASH);

      // ...and loses it again on revoke.
      await registry.connect(user).revokeAccess(verifier.address);
      await expect(
        registry.connect(verifier).getDocTypeHash(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
    });

    it("17. getDocTypeHash reverts NoKYCRecord for an address that never submitted", async () => {
      await expect(
        registry.connect(stranger).getDocTypeHash(stranger.address)
      ).to.be.revertedWithCustomError(registry, "NoKYCRecord");
    });

    it("18. accessExpiry exposes the raw grant timestamp, 0 when absent", async () => {
      expect(
        await registry.accessExpiry(user.address, verifier.address)
      ).to.equal(0n);

      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      expect(
        await registry.accessExpiry(user.address, verifier.address)
      ).to.equal(BigInt(expiresAt));

      await registry.connect(user).revokeAccess(verifier.address);
      expect(
        await registry.accessExpiry(user.address, verifier.address)
      ).to.equal(0n);
    });
  });

  describe("record versioning / consent binding", () => {
    beforeEach(async () => {
      await registry.connect(user).submitKYC(CID_1, DOC_HASH);
    });

    it("19. version starts at 1 and increments on every re-upload", async () => {
      expect(await registry.recordVersion(user.address)).to.equal(1);
      expect(await registry.recordVersion(stranger.address)).to.equal(0);

      await registry.connect(user).submitKYC(CID_2, DOC_HASH);
      expect(await registry.recordVersion(user.address)).to.equal(2);
    });

    it("20. a re-upload INVALIDATES an outstanding grant", async () => {
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        true
      );

      // The user re-uploads a DIFFERENT bundle with a different doc-type set.
      const NEW_DOC_HASH = ethers.keccak256(
        ethers.toUtf8Bytes("passport,bank_statement")
      );
      await registry.connect(user).submitKYC(CID_2, NEW_DOC_HASH);

      // The old grant no longer covers the new bundle: the verifier consented
      // to Aadhaar+PAN and must not silently receive a passport.
      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        false
      );
      await expect(
        registry.connect(verifier).getKYC(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");
      await expect(
        registry.connect(verifier).getDocTypeHash(user.address)
      ).to.be.revertedWithCustomError(registry, "NotAuthorized");

      // The expiry itself is untouched — it is the VERSION that lapsed, and
      // the getters make that diagnosable.
      expect(
        await registry.accessExpiry(user.address, verifier.address)
      ).to.equal(BigInt(expiresAt));
      expect(await registry.grantVersion(user.address, verifier.address))
        .to.equal(1);
      expect(await registry.recordVersion(user.address)).to.equal(2);
    });

    it("21. re-granting after a re-upload restores access to the NEW bundle",
      async () => {
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      await registry.connect(user).submitKYC(CID_2, DOC_HASH);
      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        false
      );

      // Deliberate re-consent against version 2.
      await expect(
        registry.connect(user).grantAccess(verifier.address, expiresAt)
      )
        .to.emit(registry, "AccessGranted")
        .withArgs(user.address, verifier.address, expiresAt, 2);

      expect(await registry.hasAccess(user.address, verifier.address)).to.equal(
        true
      );
      const [cid] = await registry.connect(verifier).getKYC(user.address);
      expect(cid).to.equal(CID_2);
    });

    it("22. the user always reads their own record, whatever the version",
      async () => {
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      await registry.connect(user).submitKYC(CID_2, DOC_HASH);
      // Self-access is not version-gated.
      expect(await registry.hasAccess(user.address, user.address)).to.equal(true);
      const [cid] = await registry.connect(user).getKYC(user.address);
      expect(cid).to.equal(CID_2);
    });

    it("23. revoke clears the recorded grant version", async () => {
      const expiresAt = (await time.latest()) + ONE_HOUR;
      await registry.connect(user).grantAccess(verifier.address, expiresAt);
      expect(await registry.grantVersion(user.address, verifier.address))
        .to.equal(1);

      await registry.connect(user).revokeAccess(verifier.address);
      expect(await registry.grantVersion(user.address, verifier.address))
        .to.equal(0);
    });

    it("24. a never-granted verifier is denied even though both versions read 0",
      async () => {
      // Regression guard for the obvious way to get this wrong: comparing
      // grantVersion == recordVersion ALONE would return true for a stranger
      // against a user who has never submitted (0 == 0). The expiry check must
      // come first and reject it.
      expect(
        await registry.hasAccess(stranger.address, verifier.address)
      ).to.equal(false);
      expect(await registry.recordVersion(stranger.address)).to.equal(0);
      expect(
        await registry.grantVersion(stranger.address, verifier.address)
      ).to.equal(0);
      // ...and on a user who HAS submitted but never granted.
      expect(await registry.hasAccess(user.address, stranger.address)).to.equal(
        false
      );
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
