.DEFAULT_GOAL := help

APP_NAME    := Nubbin
APP         := build/$(APP_NAME).app
SIGN_IDENTITY  ?= -
CODESIGN_FLAGS ?=
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app
HOOK_BIN    := $(INSTALLED)/Contents/MacOS/$(APP_NAME)
EXTENSION   := integrations/nubbin-extension.ts
PI_EXT      := $(HOME)/.pi/agent/extensions/nubbin.ts
OMP_EXT     := $(HOME)/.omp/agent/extensions/nubbin.ts

help: ## Display this help text
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# =============================================================================
# Build
# =============================================================================

##@ Build

build: ## Compile the release binary
	swift build -c release

# The icon is an Icon Composer bundle; actool (Xcode) compiles it to Assets.car for macOS 26+
# plus an AppIcon.icns fallback for older systems.
# SIGN_IDENTITY defaults to ad-hoc; release CI passes a Developer ID and hardened-runtime flags.
app: build ## Assemble and sign build/Nubbin.app
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp scripts/install_hooks.py $(EXTENSION) $(APP)/Contents/Resources/
	xcrun actool Resources/AppIcon.icon --compile $(APP)/Contents/Resources --platform macosx \
		--minimum-deployment-target 14.0 --app-icon AppIcon \
		--output-partial-info-plist build/AppIcon-partial.plist >/dev/null
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" $(APP)

dmg: app ## Package build/Nubbin.dmg for drag-to-install
	scripts/make_dmg.sh $(APP) build/$(APP_NAME).dmg

install: app ## Install to ~/Applications
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED)
	cp -R $(APP) $(INSTALLED)

run: install ## Install, then restart the app
	-pkill -x $(APP_NAME)
	while pgrep -x $(APP_NAME) >/dev/null; do sleep 0.1; done
	open $(INSTALLED)

clean: ## Remove build output
	rm -rf .build build

# =============================================================================
# Agents
# =============================================================================

##@ Agents

# Claude Code + Codex hooks, and the pi/omp extension (same file, agent name baked in).
hooks: ## Connect Claude Code, Codex, pi and omp
	python3 scripts/install_hooks.py --agent claude --binary "$(HOOK_BIN)"
	python3 scripts/install_hooks.py --agent codex --binary "$(HOOK_BIN)"
	sed 's/__AGENT__/pi/' $(EXTENSION) > $(PI_EXT)
	sed 's/__AGENT__/omp/' $(EXTENSION) > $(OMP_EXT)

unhooks: ## Disconnect every agent
	python3 scripts/install_hooks.py --agent claude --uninstall
	python3 scripts/install_hooks.py --agent codex --uninstall
	rm -f $(PI_EXT) $(OMP_EXT)

.PHONY: help build app dmg install run clean
.PHONY: hooks unhooks
