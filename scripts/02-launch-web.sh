#!/usr/bin/env bash
# M3: web security group + one Amazon Linux 2023 t3.micro (Role=web) in private subnet A.
# No key pair, no public IP, no inbound rules, IMDSv2 only. Reached through SSM; configured by Ansible.
# Writes IDs to state/ec2.env for teardown.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cli

VPC_STATE="$(state_dir)/vpc.env"
[[ -f "$VPC_STATE" ]] || { echo "No state/vpc.env. Run ./scripts/01-create-vpc.sh first."; exit 1; }
# shellcheck disable=SC1090
source "$VPC_STATE"

STATE="$(state_dir)/ec2.env"
if [[ -f "$STATE" ]] && grep -q '^INSTANCE_ID=' "$STATE"; then
  echo "Instance already recorded in $STATE. Teardown first or remove state if stale."
  exit 1
fi
touch "$STATE"
save() { echo "$1=$2" >> "$STATE"; }
trap 'echo; echo "Launch failed partway. Run ./scripts/99-teardown.sh now so nothing keeps billing."' ERR

INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
ROLE_NAME="$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)"

echo_step "Attaching CloudWatchAgentServerPolicy to role ${ROLE_NAME} (needed by the CloudWatch agent)"
CW_POLICY_ARN="arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
     --query "AttachedPolicies[?PolicyArn=='${CW_POLICY_ARN}']" --output text | grep -q .; then
  echo_ok "already attached"
else
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$CW_POLICY_ARN"
  save CW_POLICY_ATTACHED_BY_SCRIPT yes
  save ROLE_NAME "$ROLE_NAME"
  echo_ok "attached"
fi

echo_step "Log groups for nginx (7-day retention)"
for lg in "${LOG_GROUP_PREFIX}/nginx/access" "${LOG_GROUP_PREFIX}/nginx/error"; do
  aws logs create-log-group --log-group-name "$lg" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$lg" --retention-in-days 7
done
save LOG_GROUPS_CREATED yes
echo_ok "${LOG_GROUP_PREFIX}/nginx/{access,error}"

echo_step "Web security group (no inbound rules yet; M4 adds HTTP from the ALB only)"
SG_WEB="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${PROJECT_NAME}-web-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG_WEB" == "None" ]]; then
  SG_WEB="$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
    --group-name "${PROJECT_NAME}-web-sg" --description "Web tier: no inbound; egress for SSM, dnf, CloudWatch" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT_NAME}-web-sg},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query GroupId --output text)"
fi
save SG_WEB "$SG_WEB"
echo_ok "SG $SG_WEB"

echo_step "Launching ${INSTANCE_TYPE} (Amazon Linux 2023) in ${SUBNET_PRIVATE_A}"
AMI_ID="$(aws ssm get-parameter --name "$AL2023_SSM_PARAM" --query Parameter.Value --output text)"
INSTANCE_ID="$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_PRIVATE_A" --security-group-ids "$SG_WEB" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1" \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-web-1},{Key=Project,Value=${PROJECT_NAME}},{Key=Role,Value=web}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${PROJECT_NAME}-web-1},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query 'Instances[0].InstanceId' --output text)"
save INSTANCE_ID "$INSTANCE_ID"
echo "Waiting for $INSTANCE_ID to be running ..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo_ok "running ($AMI_ID)"

echo_step "Waiting for SSM registration (can take 1-3 minutes)"
for _ in $(seq 1 30); do
  ping_status="$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$ping_status" == "Online" ]] && break
  sleep 10
done
[[ "$ping_status" == "Online" ]] || { echo "Instance not Online in SSM yet (status: ${ping_status:-none}). Re-check in a minute."; exit 1; }
echo_ok "SSM Online"

trap - ERR
echo
echo_ok "Wrote $STATE. Next: ./scripts/04-run-ansible.sh (from WSL)"
