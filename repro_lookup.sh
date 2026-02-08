#!/bin/bash

# Login and get cookie
echo "Logging in..."
curl -c cookies.txt -X POST http://localhost:3000/api/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "password"}'

echo "Cookie file content:"
cat cookies.txt

# Trigger lookup for a file
LIBRARY_ID="7a459896-1da4-44e1-88fa-f630d94b614c" # Movies
FILE_PATH="New Movies/Civil.War.2024.1080p.AMZN.WEBRip.DDP5.1.x265.10bit-LAMA.mkv"
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$FILE_PATH'''))")

echo "Triggering lookup for: $FILE_PATH"
curl -v -b cookies.txt "http://localhost:3000/api/lookup?library_id=$LIBRARY_ID&path=$ENCODED_PATH"
