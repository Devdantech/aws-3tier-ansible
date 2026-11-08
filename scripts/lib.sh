#!/usr/bin/env bash
# Shared helpers for M1 Bash/AWS CLI scripts.
set -euo pipefail

: "${AWS_REGION:=us-east-2}"
: "${AWS_PROFILE:?Set AWS_PROFILE to your AWS CLI profile}"
: "${PROJECT_NAME:=aws-3tier-ansible}"
: "${ENVIRONMENT:=lab}"

: "${INSTANCE_PROFILE:=dj-3tier-ec2-role}"

# Git Bash rewrites args that start with "/" (e.g. SSM parameter names) into Windows paths. Turn that off.
export MSYS_NO_PATHCONV=1
export AWS_REGION AWS_PROFILE AWS_DEFAULT_REGION="$AWS_REGION" PROJECT_NAME ENVIRONMENT INSTANCE_PROFILE

# Latest Amazon Linux 2023 x86_64 AMI, resolved through the public SSM parameter.
AL2023_SSM_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
LOG_GROUP_PREFIX="/${PROJECT_NAME}"

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
