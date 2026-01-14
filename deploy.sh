#!/bin/bash
set -e

HOST="borisk@padre.rus9n.com"
DIR="/media/media1/sratim"

echo "🚀 Deploying to $HOST:$DIR..."

# 1. Sync source code
# Excludes target (huge), movies (large media), and git metadata
echo "📂 Syncing files..."
rsync -avz --progress \
    --exclude 'target' \
    --exclude 'movies' \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude 'deploy.sh' \
    ./ "$HOST:$DIR/"

# 2. Build on remote
echo "🛠️  Building release binary..."
ssh "$HOST" "cd $DIR && cargo build --release"

echo "✅ Deployment complete!"
echo "To start the server remotely trying running:"
echo "ssh $HOST \"cd $DIR && ./target/release/sratim\""
