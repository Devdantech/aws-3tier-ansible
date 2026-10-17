#!/usr/bin/env bash
# Shared helpers for M1 Bash/AWS CLI scripts.
set -euo pipefail

: "${AWS_REGION:=us-east-2}"
: "${AWS_PROFILE:=devdan-admin}"
: "${PROJECT_NAME:=aws-3tier-ansible}"
: "${ENVIRONMENT:=lab}"

export AWS_REGION AWS_PROFILE AWS_DEFAULT_REGION="$AWS_REGION" PROJECT_NAME ENVIRONMENT

COMMON_TAGS="Key=Project,Value=${PROJECT_NAME} Key=Environment,Value=${ENVIRONMENT} Key=ManagedBy,Value=cli"

require_cli() {
  command -v aws >/dev/null 2>&1 || { echo "aws CLI not found"; exit 1; }
  aws sts get-caller-identity >/dev/null || { echo "AWS credentials not configured (run aws configure or set env)"; exit 1; }
}

state_dir() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state"
  mkdir -p "$d"
  echo "$d"
}

echo_ok() { printf 'OK: %s\n' "$*"; }
echo_step() { printf '\n==> %s\n' "$*"; }
