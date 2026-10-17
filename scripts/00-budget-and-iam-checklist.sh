#!/usr/bin/env bash
# M1 prep (manual + CLI helpers). Budget alarm + MFA admin are one-time account steps.
# This script prints the exact checklist and creates a $20 monthly budget alarm if BUDGET_EMAIL is set.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_cli

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

cat <<TXT
M1 account hygiene (do once, then screenshot for docs/)
1. Root: enable MFA. Do not use root for lab work after that.
2. Create an IAM admin user (or assume an admin role) with MFA. Use that identity for these scripts.
3. Attach a permission boundary or keep the lab in a dedicated account if you have one.
4. Set AWS_REGION (default us-east-2) and AWS_PROFILE (default devdan-admin) and ensure your CLI profile works: aws sts get-caller-identity

Account: ${ACCOUNT_ID}
Region:  ${AWS_REGION}
TXT

if [[ -z "${BUDGET_EMAIL:-}" ]]; then
  echo
  echo "Skip budget create: export BUDGET_EMAIL=you@example.com and re-run to create a \$20/mo alarm."
  exit 0
fi

BUDGET_NAME="${PROJECT_NAME}-monthly"
echo_step "Creating/updating budget ${BUDGET_NAME} (\$20 limit) -> ${BUDGET_EMAIL}"

# Budgets API wants a JSON limit + notification. Idempotent-ish: delete then create is safer than patch.
aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null 2>&1 && \
  aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" || true

aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget "{
    \"BudgetName\": \"${BUDGET_NAME}\",
    \"BudgetLimit\": {\"Amount\": \"20\", \"Unit\": \"USD\"},
    \"TimeUnit\": \"MONTHLY\",
    \"BudgetType\": \"COST\",
    \"CostFilters\": {},
    \"CostTypes\": {
      \"IncludeTax\": true,
      \"IncludeSubscription\": true,
      \"UseBlended\": false,
      \"IncludeRefund\": true,
      \"IncludeCredit\": true,
      \"IncludeUpfront\": true,
      \"IncludeRecurring\": true,
      \"IncludeOtherSubscription\": true,
      \"IncludeSupport\": true,
      \"IncludeDiscount\": true,
      \"UseAmortized\": false
    }
  }" \
  --notifications-with-subscribers "[
    {
      \"Notification\": {
        \"NotificationType\": \"ACTUAL\",
        \"ComparisonOperator\": \"GREATER_THAN\",
        \"Threshold\": 80,
        \"ThresholdType\": \"PERCENTAGE\",
        \"NotificationState\": \"ALARM\"
      },
      \"Subscribers\": [{\"SubscriptionType\": \"EMAIL\", \"Address\": \"${BUDGET_EMAIL}\"}]
    }
  ]"

echo_ok "Budget ${BUDGET_NAME} created (alert at 80% of \$20)"
