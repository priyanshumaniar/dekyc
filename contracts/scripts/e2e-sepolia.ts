import { ethers, artifacts } from "hardhat";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

/**
 * Live end-to-end proof against the DEPLOYED Sepolia contracts.
 *
 * Walks the exact path the Flutter app walks, using the same wire formats:
 *   encrypt (AES-256-GCM, nonce ‖ ciphertext ‖ tag)
 *     → pin ciphertext to IPFS via Pinata
 *     → submitKYC(cid, docTypeHash)
 *     → read back as the owner
 *     → grantAccess(verifier, +1h)
 *     → read as the VERIFIER (eth_call with from = verifier)
 *     → fetch from the gateway, decrypt, compare to the original bytes
 *     → revokeAccess  → verifier read now reverts
 *     → attest a soulbound badge  → validBadgeCount reflects it
 *
 * Run: npm run e2e:sepolia
 *
 * Costs a little Sepolia ETH and one small Pinata pin. Prints no secrets.
 */

const DOC_TYPES = "aadhaar_front,aadhaar_back,pan,photo";

/**
 * Merge both .env files. The chain settings live in `contracts/.env`, but the
 * Pinata credentials belong to the Flutter app and live in the repo-root
 * `.env` — this script is the one place that needs both.
 */
function readEnv(): Record<string, string> {
  const files = [
    path.resolve(__dirname, "..", ".env"),
    path.resolve(__dirname, "..", "..", ".env"),
  ];
  const out: Record<string, string> = {};
  for (const file of files) {
    if (!fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
      if (!/^[A-Z_]+=/.test(line)) continue;
      const i = line.indexOf("=");
      out[line.slice(0, i)] = line.slice(i + 1).trim();
    }
  }
  return out;
}

/** Same envelope the Dart EncryptionService produces. */
function encrypt(key: Buffer, plaintext: Buffer): Buffer {
  const nonce = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", key, nonce);
  const body = Buffer.concat([c.update(plaintext), c.final()]);
  return Buffer.concat([nonce, body, c.getAuthTag()]);
}

function decrypt(key: Buffer, blob: Buffer): Buffer {
  const nonce = blob.subarray(0, 12);
  const tag = blob.subarray(blob.length - 16);
  const body = blob.subarray(12, blob.length - 16);
  const d = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(body), d.final()]);
}

async function pinToIpfs(jwt: string, bytes: Buffer): Promise<string> {
  const form = new FormData();
  form.append("file", new Blob([new Uint8Array(bytes)]), "dekyc_e2e.enc");
  form.append("pinataOptions", JSON.stringify({ cidVersion: 1 }));
  const res = await fetch("https://api.pinata.cloud/pinning/pinFileToIPFS", {
    method: "POST",
    headers: { Authorization: `Bearer ${jwt}` },
    body: form,
  });
  if (!res.ok) throw new Error(`Pinata ${res.status}: ${await res.text()}`);
  return ((await res.json()) as { IpfsHash: string }).IpfsHash;
}

function step(n: number, msg: string) {
  console.log(`\n[${n}] ${msg}`);
}

/**
 * A raw `eth_call` with an explicit `from`.
 *
 * The contract's access gate keys off `msg.sender`, so the caller identity is
 * the whole point of these reads. `contract.fn.staticCall(..., { from })` is
 * NOT usable here: ethers v6 rejects a `from` that differs from the attached
 * signer, and that rejection looks exactly like a contract revert — which
 * would make an authorization test pass for entirely the wrong reason.
 * Encoding the call ourselves keeps "reverted" meaning reverted.
 */
async function callAs(
  contract: any,
  fn: string,
  args: unknown[],
  from: string
): Promise<any> {
  const data = contract.interface.encodeFunctionData(fn, args);
  const raw = await ethers.provider.call({
    to: await contract.getAddress(),
    data,
    from,
  });
  return contract.interface.decodeFunctionResult(fn, raw);
}

/** True when `callAs` reverted on-chain. */
async function reverts(
  contract: any,
  fn: string,
  args: unknown[],
  from: string
): Promise<boolean> {
  try {
    await callAs(contract, fn, args, from);
    return false;
  } catch {
    return true;
  }
}

async function main() {
  const env = readEnv();
  const [user] = await ethers.getSigners();
  // The "verifier" only ever READS, and reads are free eth_calls with an
  // explicit `from` — so a single funded wallet proves the whole path.
  const verifier = ethers.Wallet.createRandom();

  const addrFile = path.resolve(
    __dirname, "..", "..", "lib", "config", "contract_address.dart"
  );
  const src = fs.readFileSync(addrFile, "utf8");
  const registryAddr = src.match(/kKycRegistryAddress\s*=\s*"(0x[0-9a-fA-F]{40})"/)![1];
  const sbtAddr = src.match(/kKycSbtAddress\s*=\s*"(0x[0-9a-fA-F]{40})"/)![1];

  const registry = new ethers.Contract(
    registryAddr, (await artifacts.readArtifact("KYCRegistry")).abi, user
  );
  const sbt = new ethers.Contract(
    sbtAddr, (await artifacts.readArtifact("KYCSoulboundToken")).abi, user
  );

  console.log(`Registry: ${registryAddr}`);
  console.log(`SBT:      ${sbtAddr}`);
  console.log(`User:     ${user.address}`);
  console.log(`Verifier: ${verifier.address} (read-only, unfunded)`);

  // --- 1. encrypt -----------------------------------------------------------
  step(1, "Encrypt a document bundle on-device (AES-256-GCM)");
  const key = crypto.randomBytes(32);
  const bundle = Buffer.from(
    JSON.stringify({
      version: 1,
      createdAt: new Date(0).toISOString(),
      docs: {
        aadhaar_front: Buffer.from("AADHAAR-FRONT-E2E").toString("base64"),
        aadhaar_back: Buffer.from("AADHAAR-BACK-E2E").toString("base64"),
        pan: Buffer.from("PAN-E2E").toString("base64"),
        photo: Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString("base64"),
      },
    })
  );
  const cipher = encrypt(key, bundle);
  console.log(`    plaintext ${bundle.length} B -> ciphertext ${cipher.length} B`);
  if (cipher.includes(Buffer.from("aadhaar_front"))) {
    throw new Error("FAIL: plaintext leaked into the ciphertext");
  }
  console.log("    ✓ no plaintext markers in the ciphertext");

  // --- 2. pin ---------------------------------------------------------------
  step(2, "Pin the ciphertext to IPFS (Pinata)");
  const cid = await pinToIpfs(env.PINATA_JWT ?? "", cipher);
  console.log(`    ✓ CID ${cid}`);

  // --- 3. submitKYC ---------------------------------------------------------
  step(3, "submitKYC(cid, docTypeHash)");
  const docTypeHash = ethers.keccak256(ethers.toUtf8Bytes(DOC_TYPES));
  let tx = await registry.submitKYC(cid, docTypeHash);
  let rc = await tx.wait();
  console.log(`    ✓ mined in block ${rc!.blockNumber}  status=${rc!.status}`);
  console.log(`    https://sepolia.etherscan.io/tx/${tx.hash}`);

  // --- 4. owner read --------------------------------------------------------
  step(4, "Owner reads their own record");
  console.log(`    hasRecord = ${await registry.hasRecord(user.address)}`);
  const own = await registry.getKYC(user.address);
  console.log(`    getKYC -> cid=${own[0]}`);
  if (own[0] !== cid) throw new Error("FAIL: on-chain CID != pinned CID");
  console.log("    ✓ on-chain CID matches what we pinned");

  // --- 5. unauthorized read must fail --------------------------------------
  step(5, "Verifier reads BEFORE any grant (must revert)");
  if (!(await reverts(registry, "getKYC", [user.address], verifier.address))) {
    throw new Error("FAIL: unauthorized read succeeded");
  }
  console.log("    ✓ reverted as expected (NotAuthorized)");

  // --- 6. grant -------------------------------------------------------------
  step(6, "grantAccess(verifier, now + 1h)");
  const expiresAt = Math.floor(Date.now() / 1000) + 3600;
  tx = await registry.grantAccess(verifier.address, expiresAt);
  rc = await tx.wait();
  console.log(`    ✓ mined in block ${rc!.blockNumber}`);
  console.log(`    hasAccess = ${await registry.hasAccess(user.address, verifier.address)}`);
  console.log(`    accessExpiry = ${await registry.accessExpiry(user.address, verifier.address)}`);

  // --- 7. verifier read -----------------------------------------------------
  step(7, "Verifier reads AFTER the grant");
  const seen = await callAs(
    registry, "getKYC", [user.address], verifier.address
  );
  console.log(`    getKYC -> cid=${seen[0]}`);
  if (seen[0] !== cid) throw new Error("FAIL: verifier saw a different CID");
  console.log("    ✓ verifier can read the pointer");

  // --- 8. fetch + decrypt ---------------------------------------------------
  step(8, "Verifier fetches from the IPFS gateway and decrypts");
  const gateway = env.PINATA_GATEWAY || "gateway.pinata.cloud";
  let fetched: Buffer | null = null;
  for (let i = 0; i < 10; i++) {
    const r = await fetch(`https://${gateway}/ipfs/${seen[0]}`);
    if (r.ok) { fetched = Buffer.from(await r.arrayBuffer()); break; }
    await new Promise((res) => setTimeout(res, 3000));
  }
  if (!fetched) throw new Error("FAIL: could not fetch the blob from IPFS");
  console.log(`    fetched ${fetched.length} B`);
  const plain = decrypt(key, fetched);
  if (!plain.equals(bundle)) throw new Error("FAIL: decrypted bytes differ");
  const docs = JSON.parse(plain.toString()).docs;
  console.log(
    `    ✓ decrypted OK — docs: ${Object.keys(docs).join(", ")}`
  );
  console.log(
    `    ✓ aadhaar_front = "${Buffer.from(docs.aadhaar_front, "base64")}"`
  );

  // --- 9. tamper detection --------------------------------------------------
  step(9, "Tamper one byte of the downloaded blob (GCM must reject it)");
  const tampered = Buffer.from(fetched);
  tampered[20] ^= 0x01;
  try {
    decrypt(key, tampered);
    throw new Error("FAIL: tampered ciphertext decrypted");
  } catch (e: any) {
    if (String(e.message).includes("FAIL:")) throw e;
    console.log("    ✓ auth tag rejected the modified blob");
  }

  // --- 10. consent binding --------------------------------------------------
  step(10, "Re-upload must INVALIDATE the outstanding grant (consent binding)");
  console.log(`    recordVersion before = ${await registry.recordVersion(user.address)}`);
  const newBundle = encrypt(key, Buffer.from(JSON.stringify({ version: 1, docs: {} })));
  const newCid = await pinToIpfs(env.PINATA_JWT ?? "", newBundle);
  // A DIFFERENT doc-type set — the case the grant must not silently cover.
  const newDocTypeHash = ethers.keccak256(
    ethers.toUtf8Bytes("passport,bank_statement")
  );
  tx = await registry.submitKYC(newCid, newDocTypeHash);
  rc = await tx.wait();
  console.log(`    re-uploaded in block ${rc!.blockNumber}`);
  console.log(`    recordVersion after  = ${await registry.recordVersion(user.address)}`);
  console.log(`    grantVersion         = ${await registry.grantVersion(user.address, verifier.address)}`);
  console.log(`    hasAccess            = ${await registry.hasAccess(user.address, verifier.address)}`);
  if (!(await reverts(registry, "getKYC", [user.address], verifier.address))) {
    throw new Error("FAIL: stale grant still reads the NEW bundle");
  }
  console.log("    ✓ the old grant no longer reads the new bundle");

  // Re-granting against the new version restores access — deliberately.
  tx = await registry.grantAccess(verifier.address, expiresAt);
  await tx.wait();
  const reRead = await callAs(registry, "getKYC", [user.address], verifier.address);
  if (reRead[0] !== newCid) throw new Error("FAIL: re-grant did not restore access");
  console.log("    ✓ re-granting against the new version restores access");

  // --- 11. revoke -----------------------------------------------------------
  step(11, "revokeAccess(verifier)");
  tx = await registry.revokeAccess(verifier.address);
  rc = await tx.wait();
  console.log(`    ✓ mined in block ${rc!.blockNumber}`);
  console.log(`    hasAccess = ${await registry.hasAccess(user.address, verifier.address)}`);
  if (!(await reverts(registry, "getKYC", [user.address], verifier.address))) {
    throw new Error("FAIL: read still works after revoke");
  }
  console.log("    ✓ verifier read reverts again after revoke");

  // --- 11. soulbound badge --------------------------------------------------
  step(12, "Mint a soulbound badge to a fresh subject");
  const subject = ethers.Wallet.createRandom().address;
  const before = await sbt.validBadgeCount(subject);
  tx = await sbt.attest(subject, Math.floor(Date.now() / 1000) + 86400, "ipfs://dekyc-e2e");
  rc = await tx.wait();
  const tokenId = await sbt.tokenIdOf(user.address, subject);
  console.log(`    ✓ minted tokenId ${tokenId} in block ${rc!.blockNumber}`);
  console.log(`    https://sepolia.etherscan.io/tx/${tx.hash}`);
  console.log(`    isVerifiedBy = ${await sbt.isVerifiedBy(user.address, subject)}`);
  console.log(`    validBadgeCount ${before} -> ${await sbt.validBadgeCount(subject)}`);
  console.log(`    locked(${tokenId}) = ${await sbt.locked(tokenId)}`);

  step(13, "Soulbound enforcement on the LIVE contract");
  if (!(await reverts(sbt, "approve", [user.address, tokenId], subject))) {
    throw new Error("FAIL: approve succeeded on a soulbound token");
  }
  console.log("    ✓ approve() reverts (ERC-5192 conformance, live)");

  if (
    !(await reverts(
      sbt, "transferFrom", [subject, user.address, tokenId], subject
    ))
  ) {
    throw new Error("FAIL: transfer succeeded on a soulbound token");
  }
  console.log("    ✓ transferFrom() reverts — the badge is truly non-transferable");

  console.log("\n✅ END-TO-END PASSED against the live Sepolia deployment.");
}

main().catch((e) => {
  console.error("\n❌ E2E FAILED:", e.message ?? e);
  process.exitCode = 1;
});
