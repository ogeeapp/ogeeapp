import {
  createPublicClient,
  createWalletClient,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { RuntimeConfig } from "../config";
import { createRpcPool, type RpcPool } from "./rpc-pool";
import { robinhoodChain } from "./chain";

export interface ServiceClients {
  readonly logsClient: PublicClient;
  readonly stateClient: PublicClient;
  readonly txClient: PublicClient;
  readonly walletClient?: WalletClient;
  readonly pool: RpcPool;
}

export function createClients(config: RuntimeConfig, pool = createRpcPool(config)): ServiceClients {
  if (config.CHAIN_ID !== robinhoodChain.id) {
    throw new Error(`Unsupported chain id ${config.CHAIN_ID}; this service only supports 4663`);
  }

  pool.startHourlyReporter();
  const clientOptions = { chain: robinhoodChain, batch: { multicall: true } } as const;
  const logsClient = createPublicClient({
    ...clientOptions,
    transport: pool.transport("logs"),
  });
  const stateClient = createPublicClient({
    ...clientOptions,
    transport: pool.transport("state"),
  });
  const txClient = createPublicClient({
    ...clientOptions,
    transport: pool.transport("tx"),
  });

  const privateKey = config.KEEPER_PRIVATE_KEY?.trim();
  if (!privateKey) return { logsClient, stateClient, txClient, pool };

  const account = privateKeyToAccount(privateKey as `0x${string}`);
  const walletClient = createWalletClient({
    account,
    chain: robinhoodChain,
    transport: pool.transport("tx"),
  });
  return { logsClient, stateClient, txClient, walletClient, pool };
}
