import { AbiCoder, getAddress, keccak256 } from 'ethers'

export async function computePoolAddress(
  factoryAddress: string,
  [tokenA, tokenB]: [string, string],
  tickSpacing: number,
  poolFactory: any
): Promise<string> {
  const [token0, token1] = tokenA.toLowerCase() < tokenB.toLowerCase() ? [tokenA, tokenB] : [tokenB, tokenA]
  const constructorArgumentsEncoded = AbiCoder.defaultAbiCoder().encode(
    ['address', 'address', 'int24'],
    [token0, token1, tickSpacing]
  )
  const implementationAddress = (await poolFactory.poolImplementation()).toString()
  const initCode = `0x3d602d80600a3d3981f3363d3d373d3d3d363d73${implementationAddress.replace(
    '0x',
    ''
  )}5af43d82803e903d91602b57fd5bf3`
  const initCodeHash = keccak256(initCode)

  const create2Inputs = [
    '0xff',
    factoryAddress,
    // salt
    keccak256(constructorArgumentsEncoded),
    // init code hash
    initCodeHash,
  ]
  const sanitizedInputs = `0x${create2Inputs.map((i) => i.slice(2)).join('')}`
  return getAddress(`0x${keccak256(sanitizedInputs).slice(-40)}`)
}
