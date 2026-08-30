import type { ContractTransactionResponse, TransactionReceipt, TransactionResponse } from 'ethers'
import { expect } from './expect'

type Deployable = { deploymentTransaction(): ContractTransactionResponse | null }

export default async function snapshotGasCost(
  x:
    | TransactionResponse
    | Promise<TransactionResponse>
    | ContractTransactionResponse
    | Promise<ContractTransactionResponse>
    | TransactionReceipt
    | Promise<bigint>
    | bigint
    | Deployable
    | Promise<Deployable>
): Promise<void> {
  const resolved = await x
  if (typeof resolved === 'bigint') {
    expect(Number(resolved)).toMatchSnapshot()
    return
  }
  if (resolved && typeof (resolved as Deployable).deploymentTransaction === 'function') {
    const tx = (resolved as Deployable).deploymentTransaction()
    if (tx) {
      const receipt = await tx.wait()
      if (receipt) expect(Number(receipt.gasUsed)).toMatchSnapshot()
      return
    }
  }
  if (resolved && typeof (resolved as TransactionResponse).wait === 'function') {
    const receipt = await (resolved as TransactionResponse).wait()
    if (receipt) expect(Number(receipt.gasUsed)).toMatchSnapshot()
    return
  }
  if (resolved && 'gasUsed' in (resolved as TransactionReceipt)) {
    expect(Number((resolved as TransactionReceipt).gasUsed)).toMatchSnapshot()
  }
}
