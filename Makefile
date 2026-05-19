SHELL := /bin/bash

# Variables
HOST = borisk@padre.rus9n.com
REMOTE_BIN_DIR = /usr/local/bin
REMOTE_ETC_DIR = /etc/sratim
REMOTE_VAR_DIR = /var/lib/sratim
OLD_REMOTE_DIR = /home/borisk/sratim
TARGET = x86_64-unknown-linux-gnu
BINARY = target/$(TARGET)/release/sratim
SSH_KEY = $(HOME)/.ssh/id_ed25519
SSH = ssh -i $(SSH_KEY)
RSYNC = rsync -az --progress -e "ssh -i $(SSH_KEY)"

.PHONY: all bump-version build upload service-restart deploy clean test

all: deploy

# Extract, increment, and update patch version in Cargo.toml
bump-version:
	@echo "🏷️ Incrementing version in Cargo.toml..."
	@VERSION=$$(grep -E "^version =" Cargo.toml | head -n 1 | cut -d'"' -f2); \
	IFS='.' read -r major minor patch <<< "$$VERSION"; \
	NEW_PATCH=$$((patch + 1)); \
	NEW_VERSION="$$major.$$minor.$$NEW_PATCH"; \
	sed -i "s/^version = \"$$VERSION\"/version = \"$$NEW_VERSION\"/" Cargo.toml; \
	echo "🚀 Version bumped from $$VERSION to $$NEW_VERSION"

# Run tests
test:
	cargo test

# Compile release binary
build: bump-version test
	@echo "🔨 Building release binary for $(TARGET)..."
	cargo build --release --target $(TARGET)
	@echo "✅ Build complete: $(BINARY)"

# Upload files to host
upload: build
	@echo "📤 Uploading binary and service file..."
	$(SSH) $(HOST) "sudo mkdir -p $(REMOTE_BIN_DIR) $(REMOTE_ETC_DIR) $(REMOTE_VAR_DIR) $(OLD_REMOTE_DIR)"
	$(SSH) $(HOST) "sudo chown -R borisk:borisk $(REMOTE_BIN_DIR) $(REMOTE_ETC_DIR) $(REMOTE_VAR_DIR)"
	$(RSYNC) "$(BINARY)" "$(HOST):$(REMOTE_BIN_DIR)/sratim"
	$(RSYNC) "sratim.service" "$(HOST):$(OLD_REMOTE_DIR)/sratim.service"

# Install/Update service and restart on remote server
service-restart:
	@echo "🔧 Installing service and restarting..."
	$(SSH) "$(HOST)" " \
		set -e; \
		echo '🧹 Cleaning up old static frontend and templates from host...'; \
		rm -rf $(OLD_REMOTE_DIR)/frontend $(OLD_REMOTE_DIR)/templates; \
		echo '🚚 Migrating data to $(REMOTE_VAR_DIR) if present in $(OLD_REMOTE_DIR)...'; \
		if ls $(OLD_REMOTE_DIR)/*.json 1> /dev/null 2>&1; then mv -n $(OLD_REMOTE_DIR)/*.json $(REMOTE_VAR_DIR)/ || true; fi; \
		if ls $(OLD_REMOTE_DIR)/*.db 1> /dev/null 2>&1; then mv -n $(OLD_REMOTE_DIR)/*.db $(REMOTE_VAR_DIR)/ || true; fi; \
		echo '📋 Installing/updating sratim.service...'; \
		sudo cp $(OLD_REMOTE_DIR)/sratim.service /etc/systemd/system/; \
		sudo systemctl daemon-reload; \
		sudo systemctl enable sratim; \
		echo '🔄 Restarting sratim service...'; \
		sudo systemctl restart sratim; \
		echo '📋 Status:'; \
		sudo systemctl status sratim --no-pager -l; \
	"

# Full deployment lifecycle
deploy: upload service-restart
	@echo "🚀 Deployment complete!"

clean:
	cargo clean
