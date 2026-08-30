import { type BigNumberish, Contract, MaxUint256, Signature, type Signer } from 'ethers'

type SignerWithAddress = Signer & { address: string }

export async function getPermitSignature(
  wallet: SignerWithAddress,
  token: Contract,
  spender: string,
  value: BigNumberish = MaxUint256,
  deadline: BigNumberish = MaxUint256,
  permitConfig?: { nonce?: BigNumberish; name?: string; chainId?: number | bigint; version?: string }
): Promise<Signature> {
  const provider = wallet.provider!
  const [nonce, name, version, chainId, verifyingContract] = await Promise.all([
    permitConfig?.nonce ?? token.nonces(wallet.address),
    permitConfig?.name ?? token.name(),
    permitConfig?.version ?? '1',
    permitConfig?.chainId ?? (await provider.getNetwork()).chainId,
    token.getAddress(),
  ])

  const sig = await wallet.signTypedData(
    {
      name,
      version,
      chainId,
      verifyingContract,
    },
    {
      Permit: [
        { name: 'owner', type: 'address' },
        { name: 'spender', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    },
    {
      owner: wallet.address,
      spender,
      value,
      nonce,
      deadline,
    }
  )
  return Signature.from(sig)
}
