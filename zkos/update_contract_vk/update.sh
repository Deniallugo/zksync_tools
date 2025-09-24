#!/usr/bin/env bash

set -euo pipefail


# ---- defaults & flags ----

WITH_SUBMODULES=true



if [[ -z "$ERA_CONTRACTS_TAG" ]]; then
  printf "ERROR: One of the required settings is empty\n"
  exit 1
fi



verify_clean_worktree() {
# Fail if there are unstaged or staged changes
if ! git diff --quiet --no-ext-diff; then
err "Unstaged changes present in $(pwd)"; return 1
fi
if ! git diff --cached --quiet --no-ext-diff; then
err "Staged but uncommitted changes present in $(pwd)"; return 1
fi
}


checkout_tag() {
local tag="$1"
# Ensure tag exists locally; fetch tags first to be safe
git fetch --tags --prune --force
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
err "Tag '$tag' not found in repo $(pwd)"; return 1
fi
# Checkout in detached HEAD to avoid moving any branch
git -c advice.detachedHead=false checkout --detach "$tag"
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

deploy_contract() {
    CONTRACT="$1"

    # Deploy L1VerifierPlonk and print the deployed address.
    # Requires RPC_URL and DEPLOYER_KEY environment variables.
    if [[ -z "${RPC_URL:-}" || -z "${DEPLOYER_KEY:-}" ]]; then
        printf "ERROR: RPC_URL and DEPLOYER_KEY must be set\n" >&2
        return 1
    fi


    # Run forge create and capture output (preserve output even if forge fails)
    out="$(forge create "$CONTRACT" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" --broadcast 2>&1)"
    status=$?
    if [[ $status -ne 0 ]]; then
        printf "ERROR: forge create failed\n%s\n" "$out" >&2
        return 1
    fi

    # Try to extract "Deployed to: 0x..." line
    deployed_addr=$(printf '%s\n' "$out" | sed -n 's/.*Deployed to: //p' | head -n1)

    # Fallback: try to extract an address-like hex if the exact phrase differs
    if [[ -z "$deployed_addr" ]]; then
        deployed_addr=$(printf '%s\n' "$out" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n1 || true)
    fi

    if [[ -z "$deployed_addr" ]]; then
        printf "ERROR: could not determine deployed address from forge output\n%s\n" "$out" >&2
        return 1
    fi

    # Print the address to stdout for callers to consume
    printf "%s\n" "$deployed_addr"
    return 0

}


diamond_proxy=$(cast call --rpc-url "$RPC_URL" $BRIDGEHUB_ADDRESS 'getZKChain(uint256)(address)' $CHAIN_ID)


zero_addr="0x0000000000000000000000000000000000000000"
if [[ -z "$diamond_proxy" || "$diamond_proxy" == "$zero_addr" ]]; then
  printf "ERROR: diamond proxy is zero address or unavailable: %s\n" "${diamond_proxy:-<empty>}" >&2
  exit 1
fi


printf "BridgeHub diamond proxy for chain %s is at: %s\n" "$CHAIN_ID" "$diamond_proxy"

verifier=$(cast call --rpc-url "$RPC_URL" $diamond_proxy 'getVerifier()(address)')


if [[ -z "$verifier" || "$verifier" == "$zero_addr" ]]; then
  printf "ERROR: verifier is zero address or unavailable: %s\n" "${verifier:-<empty>}" >&2
  exit 1
fi

printf "Current verifier is at: %s\n" "$verifier"


current_plonk_verifier=$(cast call --rpc-url "$RPC_URL" $verifier 'plonkVerifiers(uint32)(address)' $VERIFIER_ID)

# check that given verifier id is not set yet.

if [[ -z "$current_plonk_verifier" || "$current_plonk_verifier" != "$zero_addr" ]]; then
  printf "ERROR: current plonk verifier is already set or unavailable: %s\n" "${current_plonk_verifier:-<empty>}" >&2
  exit 1
fi

owner=$(cast call --rpc-url "$RPC_URL" $verifier 'ctmOwner()(address)')

printf "CTM owner is: %s\n" "$owner"


clone_and_tag git@github.com:matter-labs/era-contracts.git "repos/era-contracts" $ERA_CONTRACTS_TAG


pushd repos/era-contracts/l1-contracts >/dev/null

printf "**** Deploying verifiers *****\n";

# Capture the function's stdout into a shell variable and propagate failure
if ! plonk_address="$(deploy_contract "contracts/state-transition/verifiers/L1VerifierPlonk.sol:L1VerifierPlonk")"; then
    printf "ERROR: deploy_contract failed\n" >&2
    exit 1
fi


if [[ -z "${plonk_address:-}" ]]; then
    printf "ERROR: deploy_contract returned empty address\n" >&2
    exit 1
fi



printf "L1VerifierPlonk deployed to: %s\n" "$plonk_address"


if ! fflonk_address="$(deploy_contract "contracts/state-transition/verifiers/L1VerifierFflonk.sol:L1VerifierFflonk")"; then
    printf "ERROR: deploy_contract failed\n" >&2
    exit 1
fi


if [[ -z "${fflonk_address:-}" ]]; then
    printf "ERROR: deploy_contract returned empty address\n" >&2
    exit 1
fi

printf "FflonkVerifierPlonk deployed to: %s\n" "$fflonk_address"

popd > /dev/null


printf "\n**** Adding verifiers to the verifier contract *****\n"

printf "Please use the calldata below (or call the command) with $owner private key\n"

printf "CALLDATA: \n"
cast calldata 'addVerifier(uint32,address,address)' $VERIFIER_ID $plonk_address $fflonk_address

printf "\n\nCOMMAND:\n"

echo "cast send --rpc-url \"$RPC_URL\" $verifier 'addVerifier(uint32,address,address)' $VERIFIER_ID $plonk_address $fflonk_address --from $owner"