import { Deployer, Reporter } from "@solarity/hardhat-migrate";

import { SfUSD__factory } from "@ethers-v6";

import { getConfig } from "@/deploy/config/config";

export = async (deployer: Deployer) => {
  const config = await getConfig();

  const sfUSD = await deployer.deployERC1967Proxy(SfUSD__factory);

  await sfUSD.__sfUSD_init(config.tokenName, config.tokenSymbol, config.rewardToken);

  await Reporter.reportContractsMD(["SfUSD", await sfUSD.getAddress()]);
};
