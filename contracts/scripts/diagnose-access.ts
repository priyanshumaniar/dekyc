import { ethers, artifacts } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Diagnoses a reported "any verifier can read any user's KYC" against the LIVE
 * contract, and dumps the full grant history for a user.
 *
 * Run: npx hardhat run scripts/diagnose-access.ts --network sepolia
 * Set USER=0x... to inspect a specific address (defaults to the deployer).
 */

async function main() {
  const src = fs.readFileSync(
    path.resolve(__dirname, "..", "..", "lib", "config", "contract_address.dart"),
    "utf8"
  );
  const registryAddr = src.match(
    /kKycRegistryAddress\s*=\s*"(0x[0-9a-fA-F]{40})"/
  )![1];

  const [deployer] = await ethers.getSigners();
  const user = process.env.USER_ADDR ?? deployer.address;

  const abi = (await artifacts.readArtifact("KYCRegistry")).abi;
  const registry = new ethers.Contract(registryAddr, abi, ethers.provider);

  console.log(`Registry: ${registryAddr}`);
  console.log(`User:     ${user}\n`);

  const hasRecord = await registry.hasRecord(user);
  console.log(`hasRecord      = ${hasRecord}`);
  if (!hasRecord) {
    console.log("No record — nothing further to check.");
    return;
  }
  console.log(`recordVersion  = ${await registry.recordVersion(user)}`);

  // --- 1. Does an address that was NEVER granted get in? -------------------
  console.log("\n[1] Random never-granted address");
  const stranger = ethers.Wallet.createRandom().address;
  console.log(`    stranger              = ${stranger}`);
  console.log(`    hasAccess(user, str)  = ${await registry.hasAccess(user, stranger)}`);
  const data = registry.interface.encodeFunctionData("getKYC", [user]);
  try {
    await ethers.provider.call({ to: registryAddr, data, from: stranger });
    console.log("    getKYC as stranger    = ❌ SUCCEEDED (access control is broken)");
  } catch {
    console.log("    getKYC as stranger    = ✅ reverted (gate holds)");
  }

  // --- 2. Does the user read their OWN record? -----------------------------
  console.log("\n[2] The user reading their own record (self-access)");
  console.log(`    hasAccess(user, user) = ${await registry.hasAccess(user, user)}`);
  try {
    await ethers.provider.call({ to: registryAddr, data, from: user });
    console.log("    getKYC as self        = SUCCEEDS (by design — you own it)");
  } catch {
    console.log("    getKYC as self        = reverted (unexpected!)");
  }

  // --- 3. What bundle does the record actually point at? -------------------
  console.log("\n[3] Current record contents (read as the owner)");
  const getKycData = registry.interface.encodeFunctionData("getKYC", [user]);
  const raw = await ethers.provider.call({
    to: registryAddr,
    data: getKycData,
    from: user,
  });
  const [cid, submittedAt] = registry.interface.decodeFunctionResult(
    "getKYC",
    raw
  );
  console.log(`    cid          = ${cid}`);
  console.log(`    submittedAt  = ${new Date(Number(submittedAt) * 1000).toISOString()}`);

  const dthData = registry.interface.encodeFunctionData("getDocTypeHash", [user]);
  const dthRaw = await ethers.provider.call({
    to: registryAddr,
    data: dthData,
    from: user,
  });
  const docTypeHash = registry.interface.decodeFunctionResult(
    "getDocTypeHash",
    dthRaw
  )[0];
  const APP_SET = ethers.keccak256(
    ethers.toUtf8Bytes("aadhaar_front,aadhaar_back,pan,photo")
  );
  const E2E_SET = ethers.keccak256(
    ethers.toUtf8Bytes("passport,bank_statement")
  );
  console.log(`    docTypeHash  = ${docTypeHash}`);
  if (docTypeHash === APP_SET) {
    console.log("      -> matches the APP's document set (uploaded from the app)");
  } else if (docTypeHash === E2E_SET) {
    console.log("      -> ⚠️  matches the E2E SCRIPT's set — this record was");
    console.log("         written by scripts/e2e-sepolia.ts, NOT by the app.");
    console.log("         Its bundle is encrypted with a throwaway script key,");
    console.log("         so no wallet-derived key can ever decrypt it.");
  } else {
    console.log("      -> unrecognised document set");
  }

  // --- 4. Every grant this user has EVER issued ----------------------------
  // NOTE: Alchemy's free tier caps eth_getLogs at a 10-block range, so a full
  // history scan is not available. Scan only a recent window.
  console.log("\n[4] Recent AccessGranted / AccessRevoked (last 9 blocks)");
  const head = await ethers.provider.getBlockNumber();
  const from = Math.max(0, head - 9);
  const granted = await registry.queryFilter(
    registry.filters.AccessGranted(user, null),
    from,
    head
  );
  const revoked = await registry.queryFilter(
    registry.filters.AccessRevoked(user, null),
    from,
    head
  );
  console.log(`    ${granted.length} AccessGranted, ${revoked.length} AccessRevoked\n`);

  const verifiers = new Set<string>();
  for (const ev of [...granted, ...revoked]) {
    verifiers.add((ev as any).args[1] as string);
  }

  const now = Math.floor(Date.now() / 1000);
  for (const v of verifiers) {
    const expiry = await registry.accessExpiry(user, v);
    const gv = await registry.grantVersion(user, v);
    const rv = await registry.recordVersion(user);
    const live = await registry.hasAccess(user, v);
    let why = "live";
    if (!live) {
      if (expiry === 0n) why = "revoked or never granted";
      else if (expiry <= BigInt(now)) why = "EXPIRED";
      else if (gv !== rv) why = `STALE (granted v${gv}, record now v${rv})`;
    }
    const left = expiry > BigInt(now) ? `${(Number(expiry) - now) / 86400} d left` : "-";
    console.log(`    ${v}`);
    console.log(`      hasAccess=${live}  expiry=${expiry}  (${left})  grantV=${gv}  recordV=${rv}  -> ${why}`);
  }
  if (verifiers.size === 0) {
    console.log("    (none — this user has never granted anybody)");
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
