SHELL := /bin/bash

# Target Hosts
HOST = borisk@padre.rus9n.com

# Deployment Paths (Identical for both Local Demo & Remote Prod)
REMOTE_BIN_DIR = /usr/local/bin
REMOTE_ETC_DIR = /etc/sratim
REMOTE_VAR_DIR = /var/lib/sratim

# SSH Options (For Remote Deploy)
SSH_KEY = $(HOME)/.ssh/id_ed25519
SSH = ssh -i $(SSH_KEY)
RSYNC = rsync -az --progress -e "ssh -i $(SSH_KEY)"

# Architectures
LOCAL_TARGET = aarch64-unknown-linux-gnu
REMOTE_TARGET = x86_64-unknown-linux-gnu

# Binary Outputs
LOCAL_BINARY = target/$(LOCAL_TARGET)/release/sratim
REMOTE_BINARY = target/$(REMOTE_TARGET)/release/sratim

.PHONY: all build-local build-remote test-local deploy-local install-local deploy-remote upload service-restart deploy-all clean

# Default to deploying the local demo version
all: deploy-local



# Run tests natively on the dev server
test-local:
	@echo "🧪 Running unit tests natively on $(LOCAL_TARGET)..."
	cargo test --target $(LOCAL_TARGET)

# Compile native release binary for the dev server (aarch64)
build-local:
	@echo "🔨 Building native release binary for $(LOCAL_TARGET)..."
	cargo build --release --target $(LOCAL_TARGET)
	@echo "✅ Native build complete: $(LOCAL_BINARY)"

# Compile cross-compiled release binary for production (x86_64)
build-remote:
	@echo "🔨 Building cross-compiled release binary for $(REMOTE_TARGET)..."
	cargo build --release --target $(REMOTE_TARGET)
	@echo "✅ Cross-compilation complete: $(REMOTE_BINARY)"

# ==========================================
# 🏠 Local Demo Deployment Workflow (aarch64)
# ==========================================

deploy-local: test-local install-local
	@echo "🚀 Local FHS deployment and service restart complete!"

install-local: build-local
	@echo "🔧 Installing native binary and service locally on dev server..."
	# Create FHS folders on the local host
	sudo mkdir -p $(REMOTE_BIN_DIR) $(REMOTE_ETC_DIR) $(REMOTE_VAR_DIR)
	# Grant ownership to 'borisk' user locally
	sudo chown -R borisk:borisk $(REMOTE_BIN_DIR) $(REMOTE_ETC_DIR) $(REMOTE_VAR_DIR)
	# Stop the local service first to avoid "Text file busy"
	sudo systemctl stop sratim || true
	# Copy native ARM64 binary and service file
	sudo cp $(LOCAL_BINARY) $(REMOTE_BIN_DIR)/sratim
	sudo cp sratim.service /etc/systemd/system/sratim.service
	# Reload systemd and restart service
	sudo systemctl daemon-reload
	sudo systemctl enable sratim
	sudo systemctl restart sratim
	@echo "📋 Local Service Status:"
	sudo systemctl status sratim --no-pager -l

# ==========================================
# ☁️ Remote Production Deployment Workflow (x86_64)
# ==========================================

deploy-remote: test-local upload service-restart
	@echo "🚀 Remote production deployment and service restart complete!"

upload: build-remote
	@echo "📤 Uploading cross-compiled x86_64 binary and service file to PADRE..."
	$(SSH) $(HOST) "sudo mkdir -p $(REMOTE_BIN_DIR) $(REMOTE_ETC_DIR) $(REMOTE_VAR_DIR)"
	$(SSH) $(HOST) "sudo chown -R borisk:borisk $(REMOTE_BIN_DIR) $(REMOTE_ETC_DIR) $(REMOTE_VAR_DIR)"
	$(RSYNC) "$(REMOTE_BINARY)" "$(HOST):$(REMOTE_BIN_DIR)/sratim"
	$(RSYNC) "sratim.service" "$(HOST):$(REMOTE_ETC_DIR)/sratim.service"

service-restart:
	@echo "🔧 Installing service and restarting remotely on PADRE..."
	$(SSH) "$(HOST)" " \
		set -e; \
		echo '📋 Installing/updating sratim.service...'; \
		sudo cp $(REMOTE_ETC_DIR)/sratim.service /etc/systemd/system/; \
		sudo systemctl daemon-reload; \
		sudo systemctl enable sratim; \
		echo '🔄 Restarting sratim service...'; \
		sudo systemctl restart sratim; \
		echo '📋 Status:'; \
		sudo systemctl status sratim --no-pager -l; \
	"

# ==========================================
# 🌐 Double-Deployment Master Workflow
# ==========================================

deploy-all:
	@echo "🏁 Starting unified double-deployment..."
	$(MAKE) test-local build-local build-remote
	$(MAKE) install-local upload service-restart
	@echo "🚀 Double deployment successful: Local Demo & Remote Production updated!"

clean:
	cargo clean

# ==========================================
# 🚀 GitHub Release Automation
# ==========================================

release-github:
	@echo "🏷️ Incrementing version in Cargo.toml..."
	@VERSION=$$(grep -E "^version =" Cargo.toml | head -n 1 | cut -d'"' -f2); \
	IFS='.' read -r major minor patch <<< "$$VERSION"; \
	NEW_PATCH=$$((patch + 1)); \
	NEW_VERSION="$$major.$$minor.$$NEW_PATCH"; \
	sed -i "s/^version = \"$$VERSION\"/version = \"$$NEW_VERSION\"/" Cargo.toml; \
	echo "🚀 Version bumped from $$VERSION to $$NEW_VERSION"; \
	echo "📦 Preparing GitHub Release for v$$NEW_VERSION..."; \
	git add Cargo.toml; \
	git commit -m "chore: bump version to v$$NEW_VERSION"; \
	git tag "v$$NEW_VERSION"; \
	git push origin main; \
	git push origin "v$$NEW_VERSION"; \
	echo "✅ Pushed tag v$$NEW_VERSION to GitHub! The Action will now build and publish."
