import { network } from 'hardhat'

export type Conn = Awaited<ReturnType<typeof network.create>>
export type EthersHelpers = Conn['ethers']
export type NetHelpers = Conn['networkHelpers']

export async function createConnection() {
  const conn = await network.create()
  return { ethers: conn.ethers, networkHelpers: conn.networkHelpers }
}
