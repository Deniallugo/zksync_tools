#!/usr/bin/env bash

set -euo pipefail


WITH_SUBMODULES=true


verify_clean_worktree() {
# Fail if there are unstaged or staged changes
if ! git diff --quiet --no-ext-diff; then
printf "Unstaged changes present in $(pwd)\n"; return 1
fi
if ! git diff --cached --quiet --no-ext-diff; then
printf "Staged but uncommitted changes present in $(pwd)\n"; return 1
fi
}


checkout_tag() {
local tag="$1"
# Ensure tag exists locally; fetch tags first to be safe
git fetch --tags --prune --force

# If there's a tag with this name, checkout the tag (detached HEAD)
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git -c advice.detachedHead=false checkout --detach "$tag"
    return $?
fi

# If it's not a tag but is a commit-ish (hash or ref that can be resolved to a commit), checkout that commit
if git rev-parse -q --verify "$tag^{commit}" >/dev/null; then
    git -c advice.detachedHead=false checkout --detach "$tag"
    return $?
fi

printf "ERROR: Tag or commit '$tag' not found in repo $(pwd)\n"; return 1
}


update_submodules_if_requested() {
if $WITH_SUBMODULES; then
if [[ -f .gitmodules ]]; then
  git submodule sync --recursive
  git submodule update --init --recursive
fi
fi
}

clone_repo() {
    local url="$1"
    local path="$2"

    if [[ -z "$url" || -z "$path" ]]; then
        printf "ERROR: clone_repo requires url and path\n"
        return 1
    fi

    # Already cloned
    if [[ -d "$path/.git" ]]; then
        printf "Git repository already present at: $path\n"
        return 0
    fi

    # If path exists but is not a git repo, move it aside to avoid partial state
    if [[ -e "$path" ]]; then
        printf "Path exists and is not a git repo.\n"
        return 1
    fi

    mkdir -p "$(dirname "$path")"

    git clone --recurse-submodules "$url" "$path"

    return 0
}


clone_and_tag() {
    local url="$1"
    local path="$2"
    local tag="$3"

    if [[ -z "$url" || -z "$path" || -z "$tag" ]]; then
        err "clone_and_tag requires url, path and tag"
        return 1
    fi

    clone_repo "$url" "$path" || return 1

    pushd "$path" >/dev/null

    verify_clean_worktree || { popd >/dev/null; return 1; }

    checkout_tag "$tag" || { popd >/dev/null; return 1; }

    update_submodules_if_requested || { popd >/dev/null; return 1; }

    popd >/dev/null

    return 0
}


build_zkstack() {
    printf "*** Compiling zkstack cli ***\n"
    pushd "repos/zksync-era-for-stack/zkstack_cli" >/dev/null
    cargo build --bin zkstack
    popd >/dev/null
}


fund_accounts() {
    pushd "ecosystem" >/dev/null
    RPC_URL=http://localhost:8545
    PRIVKEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
    find . -type f -name 'wallets.yaml' | while read -r file; do
    echo "Processing $file …"

    # extract all addresses (strips leading spaces and the "address:" prefix)
    grep -E '^[[:space:]]*address:' "$file" \
        | sed -E 's/^[[:space:]]*address:[[:space:]]*//' \
        | while read -r addr; do

        if [[ $addr =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            echo "→ Sending 10 ETH to $addr"
            cast send "$addr" \
            --value 10ether \
            --private-key "$PRIVKEY" \
            --rpc-url "$RPC_URL"
        else
            echo "⚠️  Skipping invalid address: '$addr'" >&2
        fi

        done
    done

    # Move funds from one rich wallet to another.
    cast send "0xa61464658afeaf65cccaafd3a512b69a83b77618" --value 9000ether --private-key "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6" --rpc-url "$RPC_URL"
    cast send "0x36615cf349d7f6344891b1e7ca7c72883f5dc049" --value 9000ether --private-key "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97" --rpc-url "$RPC_URL"
    popd > /dev/null
}


deploy_l1_contracts() {
    pushd "ecosystem/local_v1"

    log=$(mktemp)


    if ../../$zkstack_tool ecosystem init --deploy-paymaster=false --deploy-erc20=false --observability=false \
    --deploy-ecosystem --l1-rpc-url=http://localhost:8545 --chain era1 \
    --server-db-url=postgres://invalid --server-db-name=invalid --update-submodules=false 2>&1 | tee "$log"; then
        rc=0
    else
        rc=$?
    fi


    # If it failed
    if [ "${rc:-0}" -ne 0 ]; then
        if grep -q "Unable to perform genesis on the database" "$log"; then
            echo "Expected failure: $log"
            rc=0   # treat as success
        else
            echo "Unexpected failure: $log" >&2
            exit "$rc"
        fi
    fi

    echo "Command considered successful"

  popd > /dev/null
}


update_bridgehub_address() {
    NEW_ADDR=$bridgehub_address perl -0777 -i -pe '
    my $new = $ENV{"NEW_ADDR"};
    s{
        (\#\s*\[config\([^\)]*default_t\s*=\s*")   # everything up to opening quote
        0x[0-9a-fA-F]{40}                          # old address
        ("\.parse\(\)\.unwrap\(\)\)\])             # rest of the attribute
    }{$1$new$2}xg
    ' "repos/zksync-os-server/node/bin/src/config.rs"
}

update_operator_keys() {

  NEW_PK="$1" perl -0777 -i -pe '
  my $new = $ENV{NEW_PK} // die "NEW_PK not set\n";
  s{
    ( \#\s*\[config\([^\)]*?\bdefault_t\s*=\s*")          # up to the opening quote
    0x[0-9a-fA-F]{64}                                     # old 64-hex value
    (" \s* \. \s* into \s* \(\) \s* \) \s* \] )           # the trailing ".into()]" (spaces allowed)
    (?= \s* (?:\/\/[^\n]*\n|\s)*                          # allow whitespace/comments
        pub \s+ operator_commit_pk \s* : \s* SecretString  # ensure this is the right field
        \s* , )
  }{$1$new$2}sgx;
' "repos/zksync-os-server/lib/l1_sender/src/config.rs"


  NEW_PK="$2" perl -0777 -i -pe '
  my $new = $ENV{NEW_PK} // die "NEW_PK not set\n";
  s{
    ( \#\s*\[config\([^\)]*?\bdefault_t\s*=\s*")          # up to the opening quote
    0x[0-9a-fA-F]{64}                                     # old 64-hex value
    (" \s* \. \s* into \s* \(\) \s* \) \s* \] )           # the trailing ".into()]" (spaces allowed)
    (?= \s* (?:\/\/[^\n]*\n|\s)*                          # allow whitespace/comments
        pub \s+ operator_prove_pk \s* : \s* SecretString  # ensure this is the right field
        \s* , )
  }{$1$new$2}sgx;
' "repos/zksync-os-server/lib/l1_sender/src/config.rs"



  NEW_PK="$3" perl -0777 -i -pe '
  my $new = $ENV{NEW_PK} // die "NEW_PK not set\n";
  s{
    ( \#\s*\[config\([^\)]*?\bdefault_t\s*=\s*")          # up to the opening quote
    0x[0-9a-fA-F]{64}                                     # old 64-hex value
    (" \s* \. \s* into \s* \(\) \s* \) \s* \] )           # the trailing ".into()]" (spaces allowed)
    (?= \s* (?:\/\/[^\n]*\n|\s)*                          # allow whitespace/comments
        pub \s+ operator_execute_pk \s* : \s* SecretString  # ensure this is the right field
        \s* , )
  }{$1$new$2}sgx;
' "repos/zksync-os-server/lib/l1_sender/src/config.rs"

}


create_genesis_file() {
    # complex upgrader 0x000000000000000000000000000000000000800f
    l2_complex_upgrader=$(yq -r ".deployedBytecode.object" repos/zksync-era/contracts/l1-contracts/out/L2ComplexUpgrader.sol/L2ComplexUpgrader.json)

    # l2 genesis upgrade 0x0000000000000000000000000000000000010001
    l2_genesis_upgrade=$(yq -r ".deployedBytecode.object" repos/zksync-era/contracts/l1-contracts/out/L2GenesisUpgrade.sol/L2GenesisUpgrade.json)

    # l2 wrapped base token (0x0000000000000000000000000000000000010007)
    l2_wrapped_base_token=$(yq -r ".deployedBytecode.object" repos/zksync-era/contracts/l1-contracts/out/L2WrappedBaseToken.sol/L2WrappedBaseToken.json)
cat > genesis.json <<EOF
{
  "initial_contracts": [
    [
      "0x000000000000000000000000000000000000800f",
      "$l2_complex_upgrader"
    ],
    [
      "0x0000000000000000000000000000000000010001",
      "$l2_genesis_upgrade"
    ],
    [
      "0x0000000000000000000000000000000000010007",
      "$l2_wrapped_base_token"
    ]
  ],
  "additional_storage": []
}
EOF
}

if [[ -z "$ZKSYNC_OS_SERVER_TAG" || -z "$ERA_CONTRACTS_TAG" || -z "$ZKSYNC_ERA_STACK_CLI_TAG" ]]; then
  printf "ERROR: One of the required settings is empty\n"
  exit 1
fi


printf "*** Fetching repositories ***\n"

clone_and_tag git@github.com:matter-labs/zksync-os-server.git "repos/zksync-os-server" $ZKSYNC_OS_SERVER_TAG
# zksync-era - checked out at the version for zkstack.
clone_and_tag git@github.com:matter-labs/zksync-era.git "repos/zksync-era-for-stack" $ZKSYNC_ERA_STACK_CLI_TAG

## Ugh.. this has to be zksync-os-integration, as zkstack is taking some configs from there.. for genesis (ugh)..
clone_and_tag git@github.com:matter-labs/zksync-era.git "repos/zksync-era" zksync-os-integration
pushd "repos/zksync-era/contracts" > /dev/null
verify_clean_worktree || { popd >/dev/null; return 1; }
checkout_tag "$ERA_CONTRACTS_TAG" || { popd >/dev/null; return 1; }
update_submodules_if_requested || { popd >/dev/null; return 1; }
popd > /dev/null


printf "*** Building zkstack cli ***\n"

build_zkstack

zkstack_tool=repos/zksync-era-for-stack/zkstack_cli/target/debug/zkstack

printf "Initializing ecosystem...\n"

pushd "ecosystem" >/dev/null

../$zkstack_tool ecosystem create --ecosystem-name local-v1 --l1-network localhost --chain-name era1 --chain-id 270 --prover-mode no-proofs --wallet-creation localhost --link-to-code ../../repos/zksync-era --l1-batch-commit-data-generator-mode rollup --start-containers false   --base-token-address 0x0000000000000000000000000000000000000001 --base-token-price-nominator 1 --base-token-price-denominator 1 --evm-emulator false

popd >/dev/null


logfile=repos/process.log

printf "Starting Anvil\n"

anvil --dump-state zkos-l1-state.json >"$logfile" 2>&1 &
pid=$!


cleanup() {
  echo "Cleaning up..."
  kill "$pid" 2>/dev/null || true
}
trap cleanup EXIT

printf "Anvil started\n"
sleep 2



fund_accounts

deploy_l1_contracts $ERA_CONTRACTS_TAG

bridgehub_address=$(grep 'bridgehub_proxy_addr:' ecosystem/local_v1/chains/era1/configs/contracts.yaml | awk '{print $2}')

deployer_pk=$(yq ".deployer.private_key" ecosystem/local_v1/chains/era1/configs/wallets.yaml)
operator_pk=$(yq ".operator.private_key" ecosystem/local_v1/chains/era1/configs/wallets.yaml)
blob_operator_pk=$(yq ".blob_operator.private_key" ecosystem/local_v1/chains/era1/configs/wallets.yaml)

printf "BridgeHub address: %s\n" "$bridgehub_address"


printf "Creating deposit transaction...\n"

pushd "repos/zksync-os-server/tools/generate-deposit" > /dev/null
cargo run -- --bridgehub "$bridgehub_address"
popd > /dev/null


printf "updating bridgehub address & operators keys in rust file...\n"

update_bridgehub_address
update_operator_keys $operator_pk $blob_operator_pk $deployer_pk



printf "creating genesis file"

# Now let's generate genesis.json file
create_genesis_file

printf "Copying genesis.json and zkos-l1-state.json to zksync-os-server...\n"

cp genesis.json repos/zksync-os-server/genesis/genesis.json
cp zkos-l1-state.json repos/zksync-os-server/genesis/zkos-l1-state.json


if ! kill -0 "$pid" 2>/dev/null; then
  echo "Process $pid crashed. Last 20 lines of log:"
  tail -n 20 "$logfile"
  exit 1
fi

printf "All done.\n"