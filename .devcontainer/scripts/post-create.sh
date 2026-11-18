#!/usr/bin/env bash
# -----------------------------------------------------------
# post-create.sh
#
# Runs once after the dev container is created.
# Called from devcontainer.json postCreateCommand.
# -----------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"

echo "==> [1/2] Python virtual environment + pre-commit"
python -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --upgrade pip
"${VENV_DIR}/bin/python" -m pip install --require-hashes \
    -r "${REPO_ROOT}/.devcontainer/requirements-dev.txt"

echo "==> [2/2] Pre-commit install hooks"
cd "${REPO_ROOT}"
"${VENV_DIR}/bin/pre-commit" install --install-hooks

echo "==> post-create complete"
