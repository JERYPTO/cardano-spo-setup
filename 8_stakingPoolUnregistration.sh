#!/bin/bash

# producer ########################################################
startTimeGenesis=$(cat ${NODE_ENVIRON}/shelley-genesis.json | jq -r .systemStart)
startTimeSec=$(date --date=${startTimeGenesis} +%s)
currentTimeSec=$(date -u +%s)
epochLength=$(cat ${NODE_ENVIRON}/shelley-genesis.json | jq -r .epochLength)
epoch=$(( (${currentTimeSec}-${startTimeSec}) / ${epochLength} ))
echo current epoch: ${epoch}

poolRetireMaxEpoch=$(cat ${NODE_ENVIRON}/params.json | jq -r '.poolRetireMaxEpoch')
echo poolRetireMaxEpoch: ${poolRetireMaxEpoch}
minRetirementEpoch=$(( ${epoch} + 1 ))
maxRetirementEpoch=$(( ${epoch} + ${poolRetireMaxEpoch} ))
echo earliest epoch for retirement is: ${minRetirementEpoch}
echo latest epoch for retirement is: ${maxRetirementEpoch}


# air-gapped #####################################################
cardano-cli stake-pool deregistration-certificate \
--cold-verification-key-file ${NODE_COLD}/cold.vkey \
--epoch $minRetirementEpoch \
--out-file ${NODE_TMP}/pool.dereg


# producer ########################################################
currentSlot=$(cardano-cli query tip ${NODE_NETWORK} | jq -r '.slot')
echo Current Slot: $currentSlot

cardano-cli query utxo \
    --address $(cat ${NODE_HOT}/payment.addr) \
    ${NODE_NETWORK} > ${NODE_TMP}/fullUtxo.out

tail -n +3 ${NODE_TMP}/fullUtxo.out | sort -k3 -nr > ${NODE_TMP}/balance.out

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
    echo TxIn: ${tx_in}
done < ${NODE_TMP}/balance.out
txcnt=$(cat ${NODE_TMP}/balance.out | wc -l)
echo Total ADA balance: ${total_balance}
echo Number of UTXOs: ${txcnt}

cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${NODE_HOT}/payment.addr)+${total_balance} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee 0 \
    --certificate-file ${NODE_TMP}/pool.dereg \
    --out-file ${NODE_TMP}/tx.raw

fee=$(cardano-cli transaction calculate-min-fee \
    --tx-body-file ${NODE_TMP}/tx.raw \
    --tx-in-count ${txcnt} \
    --tx-out-count 1 \
    ${NODE_NETWORK} \
    --witness-count 2 \
    --byron-witness-count 0 \
    --protocol-params-file ${NODE_ENVIRON}/params.json | awk '{ print $1 }')
echo fee: $fee

txOut=$((${total_balance}-${fee}))
echo txOut: ${txOut}

cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${NODE_HOT}/payment.addr)+${txOut} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee ${fee} \
    --certificate-file ${NODE_TMP}/pool.dereg \
    --out-file ${NODE_TMP}/tx.raw

# air-gapped #####################################################
cardano-cli transaction sign \
    --tx-body-file ${NODE_TMP}/tx.raw \
    --signing-key-file ${NODE_COLD}/payment.skey \
    --signing-key-file ${NODE_COLD}/cold.skey \
    ${NODE_NETWORK} \
    --out-file ${NODE_TMP}/tx.signed

# producer ########################################################
cardano-cli transaction submit \
    --tx-file ${NODE_TMP}/tx.signed \
    ${NODE_NETWORK}

cardano-cli stake-pool id --cold-verification-key-file \
  ${NODE_COLD}/cold.vkey \
  --output-format hex > ${NODE_TMP}/stakepoolid.txt
cat ${NODE_TMP}/stakepoolid.txt

cardano-cli query ledger-state ${NODE_NETWORK} > ${NODE_TMP}/ledger-state.json
jq -r '.esLState._delegationState._pstate._pParams."'"$(cat ${NODE_TMP}/stakepoolid.txt)"'"  // empty' ${NODE_TMP}/ledger-state.json