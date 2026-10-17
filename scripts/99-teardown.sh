#!/usr/bin/env bash
# Tear down M1 VPC stack using state/vpc.env. Safe to re-run if something is already gone.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cli

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
