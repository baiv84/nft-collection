-include .env
export

.PHONY: install build test fuzz invariant gas coverage fmt lint slither anvil allowlist deploy-local clean

install:
	forge install

build:
	forge build --sizes

test:
	forge test

fuzz:
	forge test --match-test testFuzz -vv

invariant:
	forge test --match-path "test/*.invariant.t.sol" -vv

gas:
	forge test --gas-report

coverage:
	forge coverage --no-match-path "test/*.invariant.t.sol" --no-match-coverage "(script|test)"

fmt:
	forge fmt

lint:
	forge fmt --check
	forge build

slither:
	slither . --filter-paths "lib/" --exclude-dependencies

anvil:
	anvil

# Builds the Merkle root and per-address proofs from allowlist.json
allowlist:
	forge script script/AllowlistRoot.s.sol:AllowlistRoot

# Requires a running node and PRIVATE_KEY in .env
deploy-local:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(RPC_URL_LOCAL) --broadcast

clean:
	forge clean
