#!/usr/bin/env bash
# Runs Slither on each deployable contract with solc 0.8.28 and the build's via-IR settings.
# Fails on any High-impact finding. Usage: contracts/script/ci/slither.sh (needs python3 + pip).
# Sources are copied to a temporary directory without foundry.toml, so crytic-compile uses solc directly
# (its Foundry integration does not read the current forge build-info format).
set -euo pipefail

SLITHER_VERSION="0.11.3"
SOLC_VERSION="0.8.28"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -m pip install --quiet --user "slither-analyzer==${SLITHER_VERSION}" "solc-select==1.1.0"
export PATH="$HOME/.local/bin:$PATH"
solc-select install "$SOLC_VERSION" >/dev/null
solc-select use "$SOLC_VERSION" >/dev/null

cp -r "$ROOT/src" "$ROOT/lib" "$WORK/"
cd "$WORK"
REMAPS="@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/ @openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/"
status=0
for target in src/PowerEngine.sol src/CrabVault.sol src/MarketHours.sol src/OgeeLens.sol \
  src/UniswapV3HedgeAdapter.sol src/UniswapV3TwapReference.sol src/PowerToken.sol; do
  echo "::group::slither $target"
  if ! slither "$target" --solc-remaps "$REMAPS" --solc-args "--via-ir --optimize --evm-version cancun" \
    --filter-paths "lib/" --exclude-informational --exclude-optimization --fail-high; then
    status=1
  fi
  echo "::endgroup::"
done
exit "$status"
