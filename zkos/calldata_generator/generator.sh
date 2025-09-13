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

clone_and_tag_with_reset() {
    local url="$1"
    local path="$2"
    local tag="$3"

    if [[ -z "$url" || -z "$path" || -z "$tag" ]]; then
        err "clone_and_tag requires url, path and tag"
        return 1
    fi

    clone_repo "$url" "$path" || return 1

    pushd "$path" >/dev/null

    git reset --hard
    git submodule update --init --recursive

    verify_clean_worktree || { popd >/dev/null; return 1; }

    checkout_tag "$tag" || { popd >/dev/null; return 1; }

    update_submodules_if_requested || { popd >/dev/null; return 1; }

    popd >/dev/null

    return 0
}



build_zkstack() {
    printf "*** Compiling zkstack cli ***\n"
    pushd "repos/zksync-era-for-stack/zkstack_cli" >/dev/null
    cargo build --release --bin zkstack
    # mess with yarn
    git reset --hard
    popd >/dev/null
}

if [[ -z "${ZKSYNC_ERA_STACK_CLI_TAG:-}" ]]; then
  ZKSYNC_ERA_STACK_CLI_TAG="origin/main"
  printf "INFO: ZKSYNC_ERA_STACK_CLI_TAG not set, defaulting to %s\n" "$ZKSYNC_ERA_STACK_CLI_TAG"
fi


if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" || -z "${GOVERNANCE_PRIVATE_KEY:-}" ]]; then
  printf "ERROR: DEPLOYER_PRIVATE_KEY and GOVERNANCE_PRIVATE_KEY must be set\n" >&2
  exit 1
fi


DEPLOYER_ADDRESS=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)
GOVERNANCE_ADDRESS=$(cast wallet address --private-key $GOVERNANCE_PRIVATE_KEY)

printf "Deployer address: $DEPLOYER_ADDRESS\n"
printf "Governance address: $GOVERNANCE_ADDRESS\n"

printf "Creating wallet.yaml\n"

cat >  testnet/configs/wallets.yaml <<EOF
deployer:
  private_key: $DEPLOYER_PRIVATE_KEY
  address: $DEPLOYER_ADDRESS
governor:
  private_key: $GOVERNANCE_PRIVATE_KEY
  address: $GOVERNANCE_ADDRESS
fee_account:
  private_key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
blob_operator:
  private_key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
operator:
  private_key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
token_multiplier_setter:
  private_key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
EOF


printf "*** Fetching repositories ***\n"

clone_and_tag git@github.com:matter-labs/zksync-era.git "repos/zksync-era-for-stack" $ZKSYNC_ERA_STACK_CLI_TAG

clone_and_tag_with_reset git@github.com:matter-labs/zksync-era.git "repos/zksync-era" origin/zksync-os-integration



printf "*** Building zkstack cli ***\n"

build_zkstack

zkstack_tool=repos/zksync-era-for-stack/zkstack_cli/target/release/zkstack


TESTNET_BRIDGEHUB=0x35A54c8C757806eB6820629bc82d90E056394C92
TESTNET_L1_RPC=https://ethereum-sepolia-rpc.publicnode.com


printf "*** Initializing & Deploying CTM ***\n"


pushd testnet/

../$zkstack_tool ecosystem init-new-ctm --bridgehub $TESTNET_BRIDGEHUB --l1-rpc-url $TESTNET_L1_RPC --zksync-os

popd > /dev/null


ctm_address=$(grep 'state_transition_proxy_addr:' testnet/configs/contracts.yaml | awk '{print $2}')


printf "CTM deployed at: $ctm_address\n"

pushd testnet/

../$zkstack_tool ecosystem register-ctm --bridgehub $TESTNET_BRIDGEHUB --l1-rpc-url $TESTNET_L1_RPC  --ctm $ctm_address -v --only_save_calldata

popd > /dev/null
