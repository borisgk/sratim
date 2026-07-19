#!/usr/bin/env bash

echo "Syncing project files to remote x86 machine (de1)..."

rsync -avz --delete \
  --exclude='.git/' \
  --exclude-from='.gitignore' \
  ./ borisk@de1.rus9n.com:/home/borisk/sratim/

echo "Sync complete. Triggering remote build..."
ssh borisk@de1.rus9n.com "cd /home/borisk/sratim && zig build -Doptimize=ReleaseFast"
echo "Remote build complete."
