#!/usr/bin/env bash

echo "Syncing project files to remote x86 machine..."

rsync -avz \
  --exclude='.git/' \
  --exclude-from='.gitignore' \
  ./ borisk@padre.rus9n.com:/home/borisk/sratim/

echo "Sync complete. NOT Triggering remote build..."
#ssh borisk@padre.rus9n.com "cd /home/borisk/sratim && zig build -Doptimize=ReleaseFast"
#echo "Remote build complete."
