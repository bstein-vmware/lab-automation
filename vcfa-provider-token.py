import requests, urllib3, sys
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Update this to your environment
FQDN = "auto-a.site-a.vcf.lab" 
BASE = f"https://{FQDN}"

if len(sys.argv) != 3:
    print("Usage: vcfa-provider-token.py <username> <password>", file=sys.stderr)
    sys.exit(1)

# Provider always uses the 'System' organization
USER, PASS = sys.argv[1], sys.argv[2]
TENANT = "System" 

s = requests.Session()
s.verify = False

# 1. Get Initial Session JWT
# Note: For Provider, the auth is USER@System
r = s.post(
    f"{BASE}/cloudapi/1.0.0/sessions", 
    auth=(f"{USER}@{TENANT}", PASS), 
    headers={"Accept": "application/json;version=40.0"}
)

jwt = r.headers.get("x-vmware-vcloud-access-token")
if not jwt:
    print(f"Login failed: {r.status_code} {r.text}", file=sys.stderr)
    sys.exit(1)

# 2. Register OAuth Client (System context)
rr = s.post(
    f"{BASE}/oauth/provider/register", # Changed from /tenant/{TENANT}/register
    json={"client_name": "provider-admin-tool"}, 
    headers={
        "Authorization": f"Bearer {jwt}", 
        "Content-Type": "application/json", 
        "Accept": "application/json;version=40.0"
    }
)

if rr.status_code not in [200, 201]:
    print(f"Registration failed: {rr.text}", file=sys.stderr)
    sys.exit(1)

cid = rr.json()["client_id"]

# 3. Exchange for Refresh Token (API Token)
tr = s.post(
    f"{BASE}/oauth/provider/token", # Changed from /tenant/{TENANT}/token
    data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", 
        "assertion": jwt, 
        "client_id": cid, 
        "scope": "openid offline_access"
    }, 
    headers={
        "Content-Type": "application/x-www-form-urlencoded", 
        "Accept": "application/json"
    }
)

if tr.status_code == 200:
    print(tr.json()["refresh_token"])
else:
    print(f"Token exchange failed: {tr.status_code} {tr.text}", file=sys.stderr)
    sys.exit(1)
