import { ethers } from "hardhat";

async function main() {
  const [deployer, wallet1] = await ethers.getSigners();

  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());

  const EffortsBank = await ethers.getContractFactory("EffortsBank");
  const effortsBank = await EffortsBank.deploy();
  await effortsBank.deployed();

  console.log("EffortsBank deployed to:", effortsBank.address);

  // Mint membership NFT to a test wallet (wallet1)
  const tx = await effortsBank.mintMembership(wallet1.address);
  await tx.wait();

  console.log("Minted membership NFT to:", wallet1.address);

  // Verify membership
  const balance = await effortsBank.balanceOf(wallet1.address);
  console.log("Wallet1 NFT balance:", balance.toString());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
