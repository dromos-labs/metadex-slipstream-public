import { type BigNumberish, MaxUint256, Signature } from 'ethers'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import { Contract } from 'ethers'

export default async function getPermitNFTSignature(
  wallet: HardhatEthersSigner,
  positionManager: Contract,
  spender: string,
  tokenId: BigNumberish,
  deadline: BigNumberish = MaxUint256,
  permitConfig?: { nonce?: BigNumberish; name?: string; chainId?: number | bigint; version?: string }
): Promise<Signature> {
  const provider = wallet.provider!
  const [nonce, name, version, chainId] = await Promise.all([
    permitConfig?.nonce ?? positionManager.positions(tokenId).then((p: any) => p.nonce),
    permitConfig?.name ?? positionManager.name(),
    permitConfig?.version ?? '1',
    permitConfig?.chainId ?? (await provider.getNetwork()).chainId,
  ])

  return Signature.from(
    await wallet.signTypedData(
      {
        name,
        version,
        chainId,
        verifyingContract: await positionManager.getAddress(),
      },
      {
        Permit: [
          {
            name: 'spender',
            type: 'address',
          },
          {
            name: 'tokenId',
            type: 'uint256',
          },
          {
            name: 'nonce',
            type: 'uint256',
          },
          {
            name: 'deadline',
            type: 'uint256',
          },
        ],
      },
      {
        owner: wallet.address,
        spender,
        tokenId,
        nonce,
        deadline,
      }
    )
  )
}
