#!/usr/bin/env bash
# M3: launch template for the web tier, matching the instance from 02-launch-web.sh.
# No subnet in the template; the M4 Auto Scaling group picks the private subnets.
# The AMI resolves from the public SSM parameter at launch time, so it always gets the latest AL2023.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cli

STATE="$(state_dir)/ec2.env"
[[ -f "$STATE" ]] || { echo "No state/ec2.env. Run ./scripts/02-launch-web.sh first."; exit 1; }
# shellcheck disable=SC1090
source "$STATE"
[[ -n "${SG_WEB:-}" ]] || { echo "SG_WEB missing from state/ec2.env."; exit 1; }
VPC_STATE="$(state_dir)/vpc.env"
# shellcheck disable=SC1090
source "$VPC_STATE"

LT_NAME="${PROJECT_NAME}-web-lt"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

LT_DATA="$(cat <<JSON
{
  "ImageId": "resolve:ssm:${AL2023_SSM_PARAM}",
  "InstanceType": "${INSTANCE_TYPE}",
  "IamInstanceProfile": { "Name": "${INSTANCE_PROFILE}" },
  "SecurityGroupIds": ["${SG_WEB}"],
  "MetadataOptions": { "HttpTokens": "required", "HttpEndpoint": "enabled", "HttpPutResponseHopLimit": 1 },
  "BlockDeviceMappings": [
    { "DeviceName": "/dev/xvda",
      "Ebs": { "VolumeSize": 8, "VolumeType": "gp3", "Encrypted": true, "DeleteOnTermination": true } }
  ],
  "TagSpecifications": [
    { "ResourceType": "instance",
      "Tags": [ {"Key": "Name", "Value": "${PROJECT_NAME}-web"},
                {"Key": "Project", "Value": "${PROJECT_NAME}"},
                {"Key": "Role", "Value": "web"} ] },
    { "ResourceType": "volume",
      "Tags": [ {"Key": "Project", "Value": "${PROJECT_NAME}"} ] }
  ]
}
JSON
)"

echo_step "Launch template ${LT_NAME}"
LT_ID="$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || echo None)"
if [[ "$LT_ID" == "None" ]]; then
  LT_ID="$(aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
    --version-description "M3 web tier" --launch-template-data "$LT_DATA" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=${PROJECT_NAME}}]" \
    --query LaunchTemplate.LaunchTemplateId --output text)"
  echo "LT_ID=$LT_ID" >> "$STATE"
  echo_ok "created $LT_ID (version 1)"
else
  ver="$(aws ec2 create-launch-template-version --launch-template-id "$LT_ID" \
    --version-description "M3 web tier" --launch-template-data "$LT_DATA" \
    --query LaunchTemplateVersion.VersionNumber --output text)"
  aws ec2 modify-launch-template --launch-template-id "$LT_ID" --default-version "$ver" >/dev/null
  grep -q '^LT_ID=' "$STATE" || echo "LT_ID=$LT_ID" >> "$STATE"
  echo_ok "$LT_ID new default version $ver"
fi

echo_step "Dry-run launch from the template into ${SUBNET_PRIVATE_B} (nothing is created)"
out="$(aws ec2 run-instances --dry-run --launch-template "LaunchTemplateId=${LT_ID}" \
  --subnet-id "$SUBNET_PRIVATE_B" 2>&1 || true)"
if grep -q DryRunOperation <<<"$out"; then
  echo_ok "template is launchable"
else
  echo "$out"; exit 1
fi
