import { Contract } from 'ethers'
import { artifacts } from 'hardhat'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'

export default function poolAtAddress(address: string, wallet: HardhatEthersSigner): Contract {
  const abi = artifacts.readArtifactSync('CLPool').abi
  return new Contract(address, abi, wallet)
}
