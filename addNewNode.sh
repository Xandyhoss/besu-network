#!/bin/bash

if ! [ -f ".env.network" ]; then
    echo ".env.network file not found. The network is not initialized."
    exit 1
fi

export $(grep -v '^#' .env.network | xargs)

NEW_NODES=1
BASE_P2P_PORT=30303
BASE_RPC_PORT=8545

while getopts n: opt; do
    case $opt in
        n)  NEW_NODES=${OPTARG}
            ;;
    esac
done

ECHO_NODES=$NEW_NODES


generate_nodes_function() {
  local nodes=""
  for ((i=NODES; i<=(NEW_NODES + NODES-1); i++)); do
    local node_name="node${i}"
    local p2p_port=$((BASE_P2P_PORT + i))
    local rpc_port=$((BASE_RPC_PORT + i))

    nodes+="
    ${node_name}:
        user: root
        container_name: ${node_name}
        image: hyperledger/besu:latest
        volumes:
        - ./../nodes/${node_name}/data:/opt/besu/data
        - ./../genesis:/opt/besu/genesis
        entrypoint:
        - /bin/bash
        - -c
        - besu --data-path=data --genesis-file=genesis/genesis.json --bootnodes=${E_ADDRESS} --p2p-port=${p2p_port} --rpc-http-enabled --rpc-http-api=ETH,NET,QBFT --host-allowlist=\"*\" --rpc-http-cors-origins=\"all\" --rpc-http-port=${rpc_port}
        ports:
        - \"${rpc_port}:${rpc_port}\"
        - \"${p2p_port}:${p2p_port}\"
        - \"${rpc_port}:${rpc_port}/udp\"
        - \"${p2p_port}:${p2p_port}/udp\"
        networks:
            besu_test_network:
        restart: always
"
  done
  echo "$nodes"
}

NODES_PARAMS=$(generate_nodes_function)

TEMPLATE_FILE="docker/nodeTemplate/nodeTemplate.yaml"
OUTPUT_FILE="docker/nodes-${ITERATION}.yaml"

echo "Generating nodes..."
if [ -f "$TEMPLATE_FILE" ]; then
    awk -v nodes="$NODES_PARAMS" '{gsub(/<NODES>/, nodes)}1' "$TEMPLATE_FILE" > "$OUTPUT_FILE"
    echo "Docker-compose file generated: $OUTPUT_FILE"
else
    echo "Template file not found: $TEMPLATE_FILE"
    exit 1
fi

echo "Starting new nodes on docker"
docker-compose -f $OUTPUT_FILE up -d

echo "Waiting for nodes to start and sync..."
sleep 10

echo "Requesting new validator status for new nodes..."
for ((i=NODES; i<=(NEW_NODES + NODES - 1); i++)); do

    MAX_TRIES=30
    TRY_COUNT=1
    
    while [ $TRY_COUNT -lt $MAX_TRIES ]; do
        export NODE_ADDRESS=$(curl -X POST --data '{"jsonrpc":"2.0","method":"eth_coinbase","params":[],"id":1}' http://localhost:$((BASE_RPC_PORT + i)) | jq -r '.result')

        if [ -n "$NODE_ADDRESS" ]; then
            if [ "$NODE_ADDRESS" != "null" ]; then
                echo "NODE_ADDRESS retrieved."
                break
            fi
        else
            echo "NODE_ADDRESS not retrieved. Trying again..."
            sleep 5
            TRY_COUNT=$((TRY_COUNT + 1))
        fi
    done

    if [ $MAX_TRIES -eq $TRY_COUNT ]; then
        echo "Failed to retrieve NODE_ADDRESS. Stopping and removing node..."
        docker stop node${i}
        docker rm node${i} -f
        break
    fi

    echo "Cleaned NODE_ADDRESS: $NODE_ADDRESS"

    echo "Starting Validator Voting Process"
    echo "Requesting validator to node ${i} from http://localhost:8545..."    
    curl -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_proposeValidatorVote\",\"params\":[\"$NODE_ADDRESS\",true],\"id\":1}" http://localhost:8545
    echo ""

    echo "Checking pending votes..."
    curl -X POST --data '{"jsonrpc":"2.0","method":"qbft_getPendingVotes","params":[], "id":1}' http://localhost:8545
    echo ""

    echo "Running requests from all validators to node${i}..."
    for ((j=1; j<=NODES-1; j++)); do
        rpc_port=$((BASE_RPC_PORT + j))
        echo "Requesting validator to node ${i} from http://localhost:${rpc_port}..."    
        curl -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_proposeValidatorVote\",\"params\":[\"$NODE_ADDRESS\",true],\"id\":1}" http://localhost:$rpc_port
        echo ""
    done

    echo "Waiting for validator to be added on list..."
    while [ true ]; do
        VALIDATOR_LIST_LENGTH=$(curl -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://localhost:8545 | jq '.result | length')
        if [ $VALIDATOR_LIST_LENGTH -eq $NODES ]; then
            echo "Validator add pending..."
            sleep 5 
            continue
        else 
            echo "Validator added!"
            break
        fi
    done
    
    echo "Close Validator Voting Process"
    echo "Closing validator voting process for ${NODE_ADDRESS} from http://localhost:8545..."    
    curl -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_discardValidatorVote\",\"params\":[\"$NODE_ADDRESS\"],\"id\":1}" http://localhost:8545
    echo ""

    for ((j=1; j<=NODES-1; j++)); do
        rpc_port=$((BASE_RPC_PORT + j))
        echo "Discard validator vote to node ${i} from http://localhost:${rpc_port}..."    
        curl -X POST --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_discardValidatorVote\",\"params\":[\"$NODE_ADDRESS\"],\"id\":1}" http://localhost:$rpc_port
        echo ""
    done

    echo "Checking pending votes..."
    curl -X POST --data '{"jsonrpc":"2.0","method":"qbft_getPendingVotes","params":[], "id":1}' http://localhost:8545
    echo ""

    NODES=$((NODES + 1))
    NEW_NODES=$((NEW_NODES - 1))
done

echo "Updating network tracker file..."
echo "NODES=$((NODES + NEW_NODES))" > .env.network
echo "ITERATION=$((ITERATION + 1))" >> .env.network
echo "E_ADDRESS=${E_ADDRESS}" >> .env.network

echo "=================================================="
echo "$ECHO_NODES validator node(s) added successfully!"
echo "=================================================="