import { keccak256, type Address, type Hex, type TransactionReceipt } from "viem";
import type { Logger } from "pino";
import type { ServiceClients } from "../chain/clients";
import { robinhoodChain } from "../chain/chain";
import { safeErrorSummary } from "../log";

export interface KeeperTransaction {
  to: Address;
  data: Hex;
  label: string;
  value?: bigint;
}

export interface TransactionResult {
  simulated: boolean;
  hash?: Hex;
  receipt?: TransactionReceipt;
}

export interface TransactionQueueOptions {
  dryRun: boolean;
  logger: Logger;
  onHash?: (transaction: KeeperTransaction, hash: Hex) => Promise<void>;
  receiptTimeoutMs?: number;
}

/** One signer, one in-flight nonce. Signing locally makes a hash available even
 * when the RPC accepts a broadcast but loses its response. Unresolved broadcasts
 * block later jobs until a known receipt is found; they never silently reuse a nonce.
 */
export function createTransactionQueue(clients: ServiceClients, options: TransactionQueueOptions) {
  const wallet = clients.walletClient;
  const account = wallet?.account;
  let tail: Promise<unknown> = Promise.resolve();
  let nextNonce: number | undefined;
  let feeCache: { value: bigint; until: number } | undefined;
  let unresolved: { nonce: number; hashes: Hex[] } | undefined;
  const timeout = options.receiptTimeoutMs ?? 60_000;

  async function receipt(hashes: Hex[]): Promise<TransactionReceipt | undefined> {
    for (const hash of hashes) {
      try { return await clients.txClient.getTransactionReceipt({ hash }); }
      catch { /* Not found or temporarily unavailable: retry within the bounded wait. */ }
    }
    return undefined;
  }

  async function wait(hashes: Hex[]): Promise<TransactionReceipt | undefined> {
    const end = Date.now() + timeout;
    let delay = 500;
    while (true) {
      const found = await receipt(hashes);
      if (found) return found;
      if (Date.now() >= end) return undefined;
      await Bun.sleep(Math.min(delay, Math.max(1, end - Date.now())));
      delay = Math.min(delay * 2, 4000);
    }
  }

  async function gasPrice(): Promise<bigint> {
    if (feeCache && feeCache.until > Date.now()) return feeCache.value;
    const value = await clients.txClient.getGasPrice();
    feeCache = { value, until: Date.now() + 300_000 };
    return value;
  }

  async function run(transaction: KeeperTransaction): Promise<TransactionResult> {
    if (!wallet || !account || account.type !== "local") throw new Error("Keeper local signer is not configured");
    if (unresolved) {
      const found = await receipt(unresolved.hashes);
      if (!found) throw new Error(`Keeper nonce ${unresolved.nonce} is unresolved; later transactions are held`);
      nextNonce = unresolved.nonce + 1;
      unresolved = undefined;
    }

    // estimateGas is the simulation: do not precede it with a redundant eth_call.
    const estimate = await clients.txClient.estimateGas({
      account: account.address, to: transaction.to, data: transaction.data,
      value: transaction.value ?? 0n,
    });
    if (options.dryRun) {
      options.logger.info({ label: transaction.label, gas: estimate.toString() }, "Keeper dry-run simulated");
      return { simulated: true };
    }

    if (nextNonce === undefined) {
      const [latest, pending] = await Promise.all([
        clients.txClient.getTransactionCount({ address: account.address, blockTag: "latest" }),
        clients.txClient.getTransactionCount({ address: account.address, blockTag: "pending" }),
      ]);
      if (latest !== pending) throw new Error("Keeper has an existing pending transaction; waiting before taking a new nonce");
      nextNonce = latest;
    }
    const nonce = nextNonce;
    let price = await gasPrice();
    const hashes: Hex[] = [];
    for (let attempt = 0; attempt < 2; attempt++) {
      const serializedTransaction = await account.signTransaction({
        chainId: robinhoodChain.id, type: "legacy", nonce,
        to: transaction.to, data: transaction.data, value: transaction.value ?? 0n,
        gas: (estimate * 120n + 99n) / 100n, gasPrice: price,
      });
      const hash = keccak256(serializedTransaction);
      hashes.push(hash);
      unresolved = { nonce, hashes };
      try { await clients.txClient.sendRawTransaction({ serializedTransaction }); }
      catch (error) {
        options.logger.warn({ label: transaction.label, hash, err: safeErrorSummary(error) },
          "Keeper broadcast response failed; checking the locally known transaction hash");
      }
      options.logger.info({ label: transaction.label, hash, nonce, replacement: attempt === 1 }, "Keeper transaction submitted");
      try { await options.onHash?.(transaction, hash); }
      catch (error) { options.logger.warn({ err: safeErrorSummary(error) }, "Could not persist keeper transaction hash"); }

      const found = await wait(hashes);
      if (found) {
        nextNonce = nonce + 1;
        unresolved = undefined;
        if (found.status !== "success") throw new Error(`Keeper transaction reverted: ${found.transactionHash}`);
        return { simulated: false, hash: found.transactionHash, receipt: found };
      }
      // One replacement, same nonce and payload, at least 20% higher gas price.
      price = (price * 120n + 99n) / 100n + 1n;
    }
    throw new Error(`Keeper transaction receipt timed out; nonce ${nonce} remains held`);
  }

  return {
    submit(transaction: KeeperTransaction): Promise<TransactionResult> {
      const result = tail.then(() => run(transaction));
      tail = result.catch(() => undefined);
      return result;
    },
    async drain(): Promise<void> { await tail; },
  };
}
