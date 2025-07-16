import { Deployer, Reporter } from "@solarity/hardhat-migrate";

import { SfUSD__factory } from "@ethers-v6";

import { getConfig } from "@/deploy/config/config";

// Note:
// Ethereum Mainnet sfUSD implementation: 0x56AEed68a14cdC975021885A8b31f89D6e43cd70

export = async (deployer: Deployer) => {
  const config = await getConfig();

  const sfUSD = await deployer.deployERC1967Proxy(SfUSD__factory);

  await sfUSD.__sfUSD_init(config.tokenName, config.tokenSymbol, config.rewardToken);

  await Reporter.reportContractsMD(["SfUSD", await sfUSD.getAddress()]);
};
