#!/usr/bin/env bash

echo "Syncing project files to remote x86 machine..."

rsync -avz \
  --exclude='.git/' \
  --exclude-from='.gitignore' \
  ./ borisk@padre.rus9n.com:/home/borisk/sratim/

echo "Sync complete."
