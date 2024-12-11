NODES=1
BASE_P2P_PORT=30303
BASE_RPC_PORT=8545

while getopts n: opt; do
    case $opt in
        n)  NODES=${OPTARG}
            ;;
    esac
done

if [ -z "$NODES" ]; then
    echo "NODES is not set. Please set the number of nodes to create."
    exit 1
fi

echo "Cleaning old files..."
sudo rm -rf tmpFiles
sudo rm -rf networkFiles
sudo rm -rf genesis
sudo rm -rf config/qbftConfigFile.json
sudo rm -rf docker/nodes.yaml

echo "Removing all containers..."
docker stop $(docker ps -a -q)
docker rm -f $(docker ps -a -q)

echo "Removing docker network..."
docker network rm besu_test_network

if ! [ -d "nodes" ]; then
    echo "Creating 'nodes' folder..."
    mkdir nodes
else
    echo "Removing previous nodes..."
    for folder in nodes/*; do
        sudo rm -rf $folder
    done
fi

echo "Creating qbftConfigFile.json based on template..."
jq '.blockchain += {
    "nodes": {
      "generate": true,
      "count": '$NODES'
    }
  }' config/configTemplate.json > config/qbftConfigFile.json

echo "Creating bootnode folder..."
mkdir nodes/bootnode

mkdir tmpFiles && cd tmpFiles
besu operator generate-blockchain-config --config-file=../config/qbftConfigFile.json --to=networkFiles --private-key-file-name=key

cd ..

counter=0
for folder in tmpFiles/networkFiles/keys/*; do
    if [ $counter -eq 0 ]; then
        echo "Copying bootnode files..."
        mkdir nodes/bootnode/data
        cp -r $folder/* nodes/bootnode/data
    else
        echo "Copying node $counter files..."
        mkdir nodes/node$counter
        mkdir nodes/node$counter/data
        cp -r $folder/* nodes/node$counter/data
    fi
    ((counter++))
done

mkdir genesis
cp tmpFiles/networkFiles/genesis.json genesis/genesis.json

echo "Removing tmpFiles..."
sudo rm -rf tmpFiles

echo "Starting bootnode on docker"
docker-compose -f docker/bootnode.yaml up -d
echo "Bootnode started"
echo "Waiting 5 seconds for bootnode to start..."
sleep 5
echo "Starting fetching to get enode..."

max_retries=30
retry_delay=3
retry_count=0

while [ $retry_count -lt $max_retries ]; do
  export ENODE=$(curl -X POST --data '{"jsonrpc":"2.0","method":"net_enode","params":[],"id":1}' http://127.0.0.1:8545 | jq -r '.result')

  if [ -n "$ENODE" ]; then
    if [ "$ENODE" != "null" ]; then
      echo "ENODE retrieved successfully."
      break
    fi
  else
    echo "Failed to retrieve ENODE. Retrying in $retry_delay seconds..."
    sleep $retry_delay
    ((retry_count++))
  fi
done

if [ $retry_count -eq $max_retries ]; then
  echo "Max retries reached. Unable to retrieve ENODE."
fi

echo "ENODE: $ENODE"

export E_ADDRESS="${ENODE#enode://}"
export DOCKER_NODE_1_ADDRESS=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' bootnode)
export E_ADDRESS=$(echo $E_ADDRESS | sed -e "s/127.0.0.1/$DOCKER_NODE_1_ADDRESS/g")
export E_ADDRESS="enode://$E_ADDRESS"

generate_nodes_function() {
  local nodes=""
  for ((i=1; i<=(NODES-1); i++)); do
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
        networks:
            besu_test_network:
        restart: always
"
  done
  echo "$nodes"
}

NODES_PARAMS=$(generate_nodes_function)

TEMPLATE_FILE="docker/nodeTemplate/nodeTemplate.yaml"
OUTPUT_FILE="docker/nodes.yaml"

if ((NODES>1)) ; then
    echo "Generating nodes..."
    if [ -f "$TEMPLATE_FILE" ]; then
        awk -v nodes="$NODES_PARAMS" '{gsub(/<NODES>/, nodes)}1' "$TEMPLATE_FILE" > "$OUTPUT_FILE"
        echo "Docker-compose file generated: $OUTPUT_FILE"
    else
        echo "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi
fi

if ((NODES>1)) ; then
    echo "Starting nodes on docker"
    docker-compose -f docker/nodes.yaml up -d
    echo "Nodes started"
fi

echo "============================="
echo "Network started successfully!"
echo "============================="