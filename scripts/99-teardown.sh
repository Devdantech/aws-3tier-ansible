#!/usr/bin/env bash
# Tear down M3 web tier (state/ec2.env), then the M1 VPC stack (state/vpc.env).
# Safe to re-run if something is already gone.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cli

EC2_STATE="$(state_dir)/ec2.env"
if [[ -f "$EC2_STATE" ]]; then
  # shellcheck disable=SC1090
  source "$EC2_STATE"
  for v in INSTANCE_ID SG_WEB LT_ID ROLE_NAME CW_POLICY_ATTACHED_BY_SCRIPT LOG_GROUPS_CREATED; do
    printf -v "$v" '%s' "${!v:-}"
  done

  echo_step "Terminating Project=${PROJECT_NAME} instances (includes any launched from the template)"
  mapfile -t ids < <(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | grep . || true)
  [[ -n "$INSTANCE_ID" ]] && ids+=("$INSTANCE_ID")
  if (( ${#ids[@]} )); then
    mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sort -u)
    aws ec2 terminate-instances --instance-ids "${ids[@]}" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "${ids[@]}" 2>/dev/null || true
    echo_ok "terminated ${ids[*]}"
  fi

  echo_step "Deleting launch template, web SG, log groups"
  [[ -n "$LT_ID" ]] && { aws ec2 delete-launch-template --launch-template-id "$LT_ID" >/dev/null 2>&1 || true; }
  [[ -n "$SG_WEB" ]] && { aws ec2 delete-security-group --group-id "$SG_WEB" 2>/dev/null || true; }
  if [[ "$LOG_GROUPS_CREATED" == "yes" ]]; then
    for lg in "${LOG_GROUP_PREFIX}/nginx/access" "${LOG_GROUP_PREFIX}/nginx/error"; do
      aws logs delete-log-group --log-group-name "$lg" 2>/dev/null || true
    done
  fi
  if [[ "$CW_POLICY_ATTACHED_BY_SCRIPT" == "yes" && -n "$ROLE_NAME" ]]; then
    aws iam detach-role-policy --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
  fi
  rm -f "$EC2_STATE"
  echo_ok "M3 resources removed. state/ec2.env removed."
fi

STATE="$(state_dir)/vpc.env"
if [[ ! -f "$STATE" ]]; then
  echo "No state/vpc.env - nothing to tear down (or state was already removed)."
  exit 0
fi
# shellcheck disable=SC1090
source "$STATE"
# Partial runs may be missing some IDs; default them to empty and skip.
for v in VPC_ID IGW_ID SUBNET_PUBLIC_A SUBNET_PUBLIC_B SUBNET_PRIVATE_A SUBNET_PRIVATE_B ALLOC_ID NAT_ID RT_PUBLIC RT_PRIVATE; do
  printf -v "$v" '%s' "${!v:-}"
done

echo_step "Deleting NAT ${NAT_ID:-none} (wait) then EIP ${ALLOC_ID:-none}"
if [[ -n "$NAT_ID" ]] && aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text 2>/dev/null | grep -vq deleted; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
  # wait until deleted
  for _ in $(seq 1 60); do
    st="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text 2>/dev/null || echo deleted)"
    [[ "$st" == "deleted" ]] && break
    sleep 10
  done
fi
[[ -n "$ALLOC_ID" ]] && { aws ec2 release-address --allocation-id "$ALLOC_ID" 2>/dev/null || true; }

echo_step "Disassociating/deleting route tables"
for rt in "$RT_PUBLIC" "$RT_PRIVATE"; do
  [[ -z "$rt" ]] && continue
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
    [[ -n "$assoc" && "$assoc" != "None" ]] && aws ec2 disassociate-route-table --association-id "$assoc" || true
  done
  aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null || true
done

echo_step "Detaching/deleting IGW and subnets"
[[ -n "$IGW_ID" ]] && { aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null || true; }
for s in "$SUBNET_PUBLIC_A" "$SUBNET_PUBLIC_B" "$SUBNET_PRIVATE_A" "$SUBNET_PRIVATE_B"; do
  [[ -z "$s" ]] && continue
  aws ec2 delete-subnet --subnet-id "$s" 2>/dev/null || true
done

echo_step "Deleting VPC $VPC_ID"
[[ -n "$VPC_ID" ]] && { aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true; }

rm -f "$STATE"
echo_ok "Teardown complete. state/vpc.env removed."
