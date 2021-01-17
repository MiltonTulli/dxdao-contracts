require('dotenv').config();
require("babel-polyfill");
require("babel-register")({
  "presets": [ "es2015" ],
  "plugins": [ "syntax-async-functions", "transform-regenerator" ]
});
require('@nomiclabs/hardhat-truffle5');
require('hardhat-gas-reporter');
require('solidity-coverage');

const INFURA_PROJECT_ID = process.env.KEY_INFURA_API_KEY;
const MNEMONIC = process.env.KEY_MNEMONIC;

module.exports = {
  solidity: {
    version: '0.5.17',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  gasReporter: {
    currency: 'USD',
    enabled: process.env.ENABLE_GAS_REPORTER === 'true'
  },
  networks: {
    hardhat: {
      gasPrice: 10000000000, // 10 gwei
      timeout: 60000
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: { mnemonic: MNEMONIC }
    },
    ropsten: {
      url: `https://ropsten.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: { mnemonic: MNEMONIC }
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: { mnemonic: MNEMONIC }
    },
    kovan: {
      url: `https://kovan.infura.io/v3/${INFURA_PROJECT_ID}`,
      accounts: { mnemonic: MNEMONIC }
    },
    coverage: {
      url: 'http://localhost:8555',
      accounts: { 
        mnemonic: MNEMONIC, 
        accountsBalance: "10000000000000000000000000000000"
      },
      gasPrice: 1,
      timeout: 60000
    }
  }
};
