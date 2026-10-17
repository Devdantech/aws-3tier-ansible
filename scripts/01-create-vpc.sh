#!/usr/bin/env bash
# M1: VPC across 2 AZs with public + private subnets, IGW, single NAT, route tables.
# Writes IDs to state/vpc.env for teardown and later milestones.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cli

STATE="$(state_dir)/vpc.env"
if [[ -f "$STATE" ]]; then
  echo "State already exists at $STATE"
  echo "Teardown first (./scripts/99-teardown.sh) or remove state if this is stale."
  exit 1
fi

# Save each ID the moment it exists, so a mid-run failure can still be torn down.
: > "$STATE"
save() { echo "$1=$2" >> "$STATE"; }
save AWS_REGION "$AWS_REGION"
save PROJECT_NAME "$PROJECT_NAME"
trap 'echo; echo "Create failed partway. Run ./scripts/99-teardown.sh now so nothing keeps billing."' ERR

CIDR_VPC="${CIDR_VPC:-10.0.0.0/16}"
# Two AZs from the region
mapfile -t AZS < <(aws ec2 describe-availability-zones \
  --region "$AWS_REGION" \
  --query 'AvailabilityZones[?State==`available`].ZoneName' \
  --output text | tr '\t' '\n' | head -2)
AZ_A="${AZS[0]}"
AZ_B="${AZS[1]}"
save AZ_A "$AZ_A"; save AZ_B "$AZ_B"

echo_step "Creating VPC ${CIDR_VPC} in ${AWS_REGION} (${AZ_A}, ${AZ_B})"
VPC_ID="$(aws ec2 create-vpc --cidr-block "$CIDR_VPC" --region "$AWS_REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_NAME}-vpc},{Key=Project,Value=${PROJECT_NAME}},{Key=Environment,Value=${ENVIRONMENT}}]" \
  --query Vpc.VpcId --output text)"
save VPC_ID "$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
echo_ok "VPC $VPC_ID"

echo_step "Internet Gateway"
IGW_ID="$(aws ec2 create-internet-gateway --region "$AWS_REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-igw},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query InternetGateway.InternetGatewayId --output text)"
save IGW_ID "$IGW_ID"
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
echo_ok "IGW $IGW_ID"

create_subnet() {
  local name="$1" cidr="$2" az="$3" public_flag="$4"
  local sid
  sid="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-${name}},{Key=Project,Value=${PROJECT_NAME}},{Key=Tier,Value=${name}}]" \
    --query Subnet.SubnetId --output text)"
  if [[ "$public_flag" == "public" ]]; then
    aws ec2 modify-subnet-attribute --subnet-id "$sid" --map-public-ip-on-launch
  fi
  echo "$sid"
}

echo_step "Subnets"
SUBNET_PUBLIC_A="$(create_subnet public-a 10.0.0.0/24 "$AZ_A" public)"
save SUBNET_PUBLIC_A "$SUBNET_PUBLIC_A"
SUBNET_PUBLIC_B="$(create_subnet public-b 10.0.1.0/24 "$AZ_B" public)"
save SUBNET_PUBLIC_B "$SUBNET_PUBLIC_B"
SUBNET_PRIVATE_A="$(create_subnet private-a 10.0.10.0/24 "$AZ_A" private)"
save SUBNET_PRIVATE_A "$SUBNET_PRIVATE_A"
SUBNET_PRIVATE_B="$(create_subnet private-b 10.0.11.0/24 "$AZ_B" private)"
save SUBNET_PRIVATE_B "$SUBNET_PRIVATE_B"
echo_ok "public $SUBNET_PUBLIC_A $SUBNET_PUBLIC_B / private $SUBNET_PRIVATE_A $SUBNET_PRIVATE_B"

echo_step "NAT Gateway (EIP in public-a) - bills hourly; tear down when done"
ALLOC_ID="$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION" \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat-eip},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query AllocationId --output text)"
save ALLOC_ID "$ALLOC_ID"
NAT_ID="$(aws ec2 create-nat-gateway --subnet-id "$SUBNET_PUBLIC_A" --allocation-id "$ALLOC_ID" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_NAME}-nat},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query NatGateway.NatGatewayId --output text)"
save NAT_ID "$NAT_ID"
echo "Waiting for NAT $NAT_ID ..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
echo_ok "NAT $NAT_ID"

echo_step "Route tables"
RT_PUBLIC="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-rt-public},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query RouteTable.RouteTableId --output text)"
save RT_PUBLIC "$RT_PUBLIC"
aws ec2 create-route --route-table-id "$RT_PUBLIC" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUBLIC" --subnet-id "$SUBNET_PUBLIC_A" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUBLIC" --subnet-id "$SUBNET_PUBLIC_B" >/dev/null

RT_PRIVATE="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_NAME}-rt-private},{Key=Project,Value=${PROJECT_NAME}}]" \
  --query RouteTable.RouteTableId --output text)"
save RT_PRIVATE "$RT_PRIVATE"
aws ec2 create-route --route-table-id "$RT_PRIVATE" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE" --subnet-id "$SUBNET_PRIVATE_A" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE" --subnet-id "$SUBNET_PRIVATE_B" >/dev/null
echo_ok "RT public $RT_PUBLIC / private $RT_PRIVATE"

trap - ERR

echo
echo_ok "Wrote $STATE"
echo "Screenshot VPC topology in console now, then run ./scripts/99-teardown.sh when finished."
