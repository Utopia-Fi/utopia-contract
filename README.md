# utopia-contract

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a script that deploys that contract.

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat compile
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
ENV=local PKEY=** npx hardhat run --network zk scripts/deploy.ts
npx hardhat flatten contracts/token/PBC.sol > flatten/token.sol



ENV=dev PKEY=** npx hardhat run --network arbTestnet deploy/scripts/nft/1_1_deploy_UtopiaSloth.ts

```

# zkSync

```shell
npx hardhat compile --network zkTestnet
ENV=local PKEY=** npx hardhat deploy-zksync --network zkTestnet --script deploy/scripts-zk/nft/1_3_initialize.ts
npx hardhat verify --network zk <contract address> --constructor-args arguments.js
```
