import { ethers, artifacts, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Checks that the addresses committed in `lib/config/contract_address.dart`
 * are actually live on the target network AND still carry the bytecode that
 * the CURRENT sources compile to.
 *
 * Run:  npm run check:sepolia
 *
 * Why this exists: `contract_address.dart` is generated at deploy time, but
 * nothing stops the contracts from being edited afterwards. Then the app would
 * silently talk to an older ABI. This script fails loudly when that drift
 * happens, so the README's "deployed at 0x…" claim stays true.
 *
 * Prints no secrets — only addresses, code sizes and booleans.
 */

const CONTRACTS = ["KYCRegistry", "KYCSoulboundToken"] as const;

/** Pull the generated addresses straight out of the Dart config. */
function readDartAddresses(): Record<string, string> {
  const dartFile = path.resolve(
    __dirname,
    "..",
    "..",
    "lib",
    "config",
    "contract_address.dart"
  );
  const src = fs.readFileSync(dartFile, "utf8");
  const grab = (name: string): string => {
    const m = src.match(new RegExp(`${name}\\s*=\\s*"(0x[0-9a-fA-F]{40})"`));
    if (!m) throw new Error(`${name} not found in ${dartFile}`);
    return m[1];
  };
  return {
    KYCRegistry: grab("kKycRegistryAddress"),
    KYCSoulboundToken: grab("kKycSbtAddress"),
  };
}

async function main() {
  const addresses = readDartAddresses();
  const net = await ethers.provider.getNetwork();
  console.log(`Network: ${network.name} (chainId ${net.chainId})`);
  console.log(`Block:   ${await ethers.provider.getBlockNumber()}\n`);

  let drift = false;

  for (const name of CONTRACTS) {
    const address = addresses[name];
    const onchain = (await ethers.provider.getCode(address)).toLowerCase();
    const artifact = await artifacts.readArtifact(name);
    const local = artifact.deployedBytecode.toLowerCase();
    const live = onchain !== "0x";
    // Trailing metadata differs per compile; compare the code body length too.
    const matches = onchain === local;

    console.log(`${name} @ ${address}`);
    console.log(`  live on-chain:    ${live ? "yes" : "NO — no code at address"}`);
    console.log(`  on-chain size:    ${(onchain.length - 2) / 2} bytes`);
    console.log(`  local build size: ${(local.length - 2) / 2} bytes`);
    console.log(`  bytecode match:   ${matches ? "yes" : "NO — source has drifted"}`);
    console.log(`  explorer:         https://sepolia.etherscan.io/address/${address}#code\n`);

    if (!live || !matches) drift = true;
  }

  // Spot-check a few live reads so we know the ABI the app ships actually works.
  const reg = new ethers.Contract(
    addresses.KYCRegistry,
    (await artifacts.readArtifact("KYCRegistry")).abi,
    ethers.provider
  );
  const sbt = new ethers.Contract(
    addresses.KYCSoulboundToken,
    (await artifacts.readArtifact("KYCSoulboundToken")).abi,
    ethers.provider
  );

  console.log("Live reads:");
  console.log(`  KYCRegistry.owner()          -> ${await reg.owner()}`);
  console.log(`  KYCRegistry.hasRecord(0x0)   -> ${await reg.hasRecord(ethers.ZeroAddress)}`);
  console.log(`  SBT.name()/symbol()          -> ${await sbt.name()} / ${await sbt.symbol()}`);
  // validBadgeCount only exists on the post-Iteration-6 deployment.
  try {
    const n = await sbt.validBadgeCount(ethers.ZeroAddress);
    console.log(`  SBT.validBadgeCount(0x0)     -> ${n} (present)`);
  } catch {
    console.log(`  SBT.validBadgeCount(0x0)     -> ABSENT (stale deployment)`);
    drift = true;
  }

  if (drift) {
    console.error(
      "\n❌ Deployment drift detected. Redeploy with `npm run deploy:sepolia`."
    );
    process.exitCode = 1;
  } else {
    console.log("\n✅ Live deployment matches the current sources.");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
