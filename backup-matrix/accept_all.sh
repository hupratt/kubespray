# grab it from element: Settings → Help & About → scroll to the very bottom → "Access Token" → click to reveal.
TOKEN="your_actual_token_here"

# Get all invite room IDs
INVITES=$(curl -s "https://matrix.thekor.eu/_matrix/client/v3/sync" \
  -H "Authorization: Bearer $TOKEN" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(r) for r in d.get('rooms',{}).get('invite',{})]")

# This does not work because of special characters
for room in $INVITES; do
  echo "Joining $room"
  curl -s -X POST "https://matrix.thekor.eu/_matrix/client/v3/join/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$room'))")" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{}'
done

# this overcomes the rate limit and deals with the special characters
python3 << EOF
import json, urllib.request, urllib.parse, time

token = "$TOKEN"
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

req = urllib.request.Request("https://matrix.thekor.eu/_matrix/client/v3/sync", headers=headers)
data = json.loads(urllib.request.urlopen(req).read())
invites = list(data.get("rooms", {}).get("invite", {}).keys())
print(f"Found {len(invites)} invites")

for room_id in invites:
    while True:
        try:
            url = f"https://matrix.thekor.eu/_matrix/client/v3/join/{urllib.parse.quote(room_id)}"
            req = urllib.request.Request(url, data=b"{}", headers=headers, method="POST")
            resp = json.loads(urllib.request.urlopen(req).read())
            print(f"Joined {room_id}")
            time.sleep(0.5)
            break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                retry = json.loads(e.read()).get("retry_after_ms", 5000) / 1000
                print(f"Rate limited, waiting {retry}s...")
                time.sleep(retry)
            else:
                print(f"Failed {room_id}: {e}")
                break
EOF