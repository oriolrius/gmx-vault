import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { getNetworkInfo } from '../network-info';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { RAGE_CLEARING_HOUSE_ADDRESS } = getNetworkInfo(hre.network.config.chainId);
  if (RAGE_CLEARING_HOUSE_ADDRESS) {
    console.log('Skipping SettlementTokenOracle.ts, using ClearingHouse from @ragetrade/core');
    return;
  }

  const {
    deployments: { deploy },
    getNamedAccounts,
  } = hre;

  const { deployer } = await getNamedAccounts();

  await deploy('SettlementTokenOracle', {
    contract: 'SettlementTokenOracle',
    from: deployer,
    log: true,
  });
};

export default func;

func.tags = ['SettlementTokenOracle'];
