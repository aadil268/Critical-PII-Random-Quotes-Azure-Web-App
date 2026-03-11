#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <resource-group-name> <web-app-name>"
  echo "Run once per web app."
  exit 1
fi

RESOURCE_GROUP="$1"
WEB_APP_NAME="$2"
WEB_APP_ID="$(az webapp show --resource-group "${RESOURCE_GROUP}" --name "${WEB_APP_NAME}" --query id -o tsv)"

PENDING_IDS="$(az network private-endpoint-connection list --id "${WEB_APP_ID}" --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv)"

if [[ -z "${PENDING_IDS}" ]]; then
  echo "No pending private endpoint connections found for ${WEB_APP_NAME}."
  exit 0
fi

while IFS= read -r connection_id; do
  [[ -z "${connection_id}" ]] && continue
  echo "Approving ${connection_id}"
  az network private-endpoint-connection approve \
    --id "${connection_id}" \
    --description "Approved for Azure Front Door private origin traffic"
done <<< "${PENDING_IDS}"

echo "Approval completed for ${WEB_APP_NAME}."
