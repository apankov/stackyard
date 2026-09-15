#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e


# Variables. Input manual
VAULT_DOMAIN=https://secrets.12devs.info
VAULT_MOUNT_PATH=twelvedevs-ad
VAULT_DEFAULT_ROLE=twelvedevs-azuread-user-role
VAULT_DEFAULT_POLICY=user-default-policy

AZURE_CLIENT_ID=2c284aa5-d928-47aa-b59a-b8c10d76d1c3
AZURE_CLIENT_ID=59a05eb2-ec1e-4ae5-ab88-f2435c4314d2
AZURE_DIRECTORY_ID=91d1a4ae-83aa-4994-ac02-2b552ff91f49
AZURE_CLIENT_SECRET=6298Q~lXqHr1OYlPadUVkY.DXQdwhShZbpmfvb.C
AZURE_CLIENT_SECRET=4uX8Q~zhw65kdrkgjUb-pDgnsBip7dSB2dtXYbyo

AZURE_AD_GROUP_ACCESS=efb5f335-055c-4a8c-b409-199c3b579dff

# variables
AZURE_DISCOVERY_URL=https://login.microsoftonline.com/${AZURE_DIRECTORY_ID}/v2.0


export VAULT_ADDR='http://127.0.0.1:8200'

vault login

vault write sys/auth/${VAULT_MOUNT_PATH} type=oidc

vault write auth/${VAULT_MOUNT_PATH}/config \
   oidc_discovery_url="${AZURE_DISCOVERY_URL}" \
   oidc_client_id="${AZURE_CLIENT_ID}" \
   oidc_client_secret="${AZURE_CLIENT_SECRET}" \
   default_role="${VAULT_DEFAULT_ROLE}"

vault write auth/${VAULT_MOUNT_PATH}/role/${VAULT_DEFAULT_ROLE} -<<EOF
{
   "allowed_redirect_uris": "${VAULT_DOMAIN}/ui/vault/auth/${VAULT_MOUNT_PATH}/oidc/callback",
   "user_claim": "email",
   "oidc_scopes": "https://graph.microsoft.com/.default",
   "groups_claim": "groups",
   "policies": ["$VAULT_DEFAULT_POLICY"],
   "ttl": "1h",
   "bound_claims": { "groups": ["${AZURE_AD_GROUP_ACCESS}"] }
}
EOF
