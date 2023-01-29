#!/bin/bash

META_URL="https://jerypto.io"

# testPoolMetaData.json should be uploaded before running this script
cat > ${NODE_TMP}/testPoolMetaData.json << EOF
{
  "name": "MTP0",
  "description": "My Test Pool",
  "ticker": "MTP",
  "homepage": "https://mtp.io"
}
EOF

# producer ########################################################

cardano-cli stake-pool metadata-hash \
    --pool-metadata-file ${NODE_TMP}/testPoolMetaData.json \
    > ${NODE_TMP}/poolMetaDataHash.txt

minPoolCost=$(cat ${NODE_ENVIRON}/params.json | jq -r .minPoolCost)
echo minPoolCost: ${minPoolCost}


# air-gapped #####################################################

cardano-cli stake-pool registration-certificate \
    --cold-verification-key-file ${NODE_COLD}/cold.vkey \
    --vrf-verification-key-file ${NODE_HOT}/vrf.vkey \
    --pool-pledge 100000000 \
    --pool-cost 345000000 \
    --pool-margin 0.15 \
    --pool-reward-account-verification-key-file ${NODE_COLD}/stake.vkey \
    --pool-owner-stake-verification-key-file ${NODE_COLD}/stake.vkey \
    --single-host-pool-relay preprod-node.world.dev.cardano.org \
    --pool-relay-port 30000 \
    ${NODE_NETWORK} \
    --metadata-url ${META_URL}/testPoolMetaData.json \
    --metadata-hash $(cat ${NODE_TMP}/poolMetaDataHash.txt) \
    --out-file ${NODE_TMP}/pool.cert

cardano-cli stake-address delegation-certificate \
    --stake-verification-key-file ${NODE_COLD}/stake.vkey \
    --cold-verification-key-file ${NODE_COLD}/cold.vkey \
    --out-file ${NODE_TMP}/deleg.cert


# producer ########################################################
currentSlot=$(cardano-cli query tip ${NODE_NETWORK} | jq -r '.slot')
echo Current Slot: $currentSlot

cardano-cli query utxo \
    --address $(cat ${NODE_HOT}/payment.addr) \
    ${NODE_NETWORK} > ${NODE_TMP}/fullUtxo.out

tail -n +3 ${NODE_TMP}/fullUtxo.out | sort -k3 -nr > ${NODE_TMP}/balance.out
cat ${NODE_TMP}/balance.out
tx_in=""
total_balance=0
while read -r utxo; do
    in_addr=$(awk '{ print $1 }' <<< "${utxo}")
    idx=$(awk '{ print $2 }' <<< "${utxo}")
    utxo_balance=$(awk '{ print $3 }' <<< "${utxo}")
    total_balance=$((${total_balance}+${utxo_balance}))
    echo TxHash: ${in_addr}#${idx}
    echo ADA: ${utxo_balance}
    tx_in="${tx_in} --tx-in ${in_addr}#${idx}"
done < ${NODE_TMP}/balance.out
txcnt=$(cat ${NODE_TMP}/balance.out | wc -l)
echo Total ADA balance: ${total_balance}
echo Number of UTXOs: ${txcnt}

stakePoolDeposit=$(cat ${NODE_ENVIRON}/params.json | jq -r '.stakePoolDeposit')
echo stakePoolDeposit: $stakePoolDeposit

cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${NODE_HOT}/payment.addr)+$(( ${total_balance} - ${stakePoolDeposit}))  \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee 0 \
    --certificate-file ${NODE_TMP}/pool.cert \
    --certificate-file ${NODE_TMP}/deleg.cert \
    --out-file ${NODE_TMP}/tx.raw

fee=$(cardano-cli transaction calculate-min-fee \
    --tx-body-file ${NODE_TMP}/tx.raw \
    --tx-in-count ${txcnt} \
    --tx-out-count 1 \
    ${NODE_NETWORK} \
    --witness-count 3 \
    --byron-witness-count 0 \
    --protocol-params-file ${NODE_ENVIRON}/params.json | awk '{ print $1 }')
echo fee: $fee

txOut=$((${total_balance}-${stakePoolDeposit}-${fee}))
echo txOut: ${txOut}

cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${NODE_HOT}/payment.addr)+${txOut} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee ${fee} \
    --certificate-file ${NODE_TMP}/pool.cert \
    --certificate-file ${NODE_TMP}/deleg.cert \
    --out-file ${NODE_TMP}/tx.raw


# air-gapped #####################################################
cardano-cli transaction sign \
    --tx-body-file ${NODE_TMP}/tx.raw \
    --signing-key-file ${NODE_COLD}/payment.skey \
    --signing-key-file ${NODE_COLD}/cold.skey \
    --signing-key-file ${NODE_COLD}/stake.skey \
    ${NODE_NETWORK} \
    --out-file ${NODE_TMP}/tx.signed


# producer ########################################################
cardano-cli transaction submit \
    --tx-file ${NODE_TMP}/tx.signed \
    ${NODE_NETWORK} 

# https://preprod.cardanoscan.io/search?filter=all&value=<Pool ID>