PROJECT_NAME=admin-console
PACKAGE_NAME:=github.com/fabric8-services/$(PROJECT_NAME)
CUR_DIR=$(shell pwd)
TMP_PATH=$(CUR_DIR)/tmp
INSTALL_PREFIX=$(CUR_DIR)/bin
VENDOR_DIR=vendor
SOURCE_DIR ?= .
SOURCES := $(shell find $(SOURCE_DIR) -path $(SOURCE_DIR)/vendor -prune -o -name '*.go' -print)
DESIGN_DIR=design
DESIGNS := $(shell find $(SOURCE_DIR)/$(DESIGN_DIR) -path $(SOURCE_DIR)/vendor -prune -o -name '*.go' -print)

# declares variable that are OS-sensitive
SELF_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
ifeq ($(OS),Windows_NT)
include $(SELF_DIR)Makefile.win
else
include $(SELF_DIR)Makefile.lnx
endif

# This is a fix for a non-existing user in passwd file when running in a docker
# container and trying to clone repos of dependencies
GIT_COMMITTER_NAME ?= "user"
GIT_COMMITTER_EMAIL ?= "user@example.com"
export GIT_COMMITTER_NAME
export GIT_COMMITTER_EMAIL

COMMIT=$(shell git rev-parse HEAD 2>/dev/null)
GITUNTRACKEDCHANGES := $(shell git status --porcelain --untracked-files=no)
ifneq ($(GITUNTRACKEDCHANGES),)
COMMIT := $(COMMIT)-dirty
endif
BUILD_TIME=`date -u '+%Y-%m-%dT%H:%M:%SZ'`

.DEFAULT_GOAL := help

# Call this function with $(call log-info,"Your message")
define log-info =
@echo "INFO: $(1)"
endef

# -------------------------------------------------------------------
# Docker build
# -------------------------------------------------------------------
BUILD_DIR = bin
REGISTRY_URI = quay.io
REGISTRY_NS = ${PROJECT_NAME}
REGISTRY_IMAGE = ${PROJECT_NAME}

ifeq ($(TARGET),rhel)
	REGISTRY_URL := ${REGISTRY_URI}/openshiftio/rhel-${REGISTRY_NS}-${REGISTRY_IMAGE}
	DOCKERFILE := Dockerfile.rhel
else
	REGISTRY_URL := ${REGISTRY_URI}/openshiftio/${REGISTRY_NS}-${REGISTRY_IMAGE}
	DOCKERFILE := Dockerfile
endif

$(BUILD_DIR):
	mkdir $(BUILD_DIR)

.PHONY: build-linux $(BUILD_DIR)
build-linux: makefiles prebuild-check deps generate ## Builds the Linux binary for the container image into bin/ folder
	CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -v $(LDFLAGS) -o $(BUILD_DIR)/$(PROJECT_NAME)

image: clean-artifacts build-linux
	docker build -t $(REGISTRY_URL) \
	  --build-arg BUILD_DIR=$(BUILD_DIR)\
	  --build-arg PROJECT_NAME=$(PROJECT_NAME)\
	  -f $(VENDOR_DIR)/github.com/fabric8-services/fabric8-common/makefile/$(DOCKERFILE) .

# -------------------------------------------------------------------
# help!
# -------------------------------------------------------------------

.PHONY: help
help: ## Prints this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort

# -------------------------------------------------------------------
# required tools
# -------------------------------------------------------------------

# Find all required tools:
GIT_BIN := $(shell command -v $(GIT_BIN_NAME) 2> /dev/null)
DEP_BIN_DIR := $(TMP_PATH)/bin
DEP_BIN := $(DEP_BIN_DIR)/$(DEP_BIN_NAME)
DEP_VERSION=v0.4.1
GO_BIN := $(shell command -v $(GO_BIN_NAME) 2> /dev/null)

$(INSTALL_PREFIX):
	mkdir -p $(INSTALL_PREFIX)
$(TMP_PATH):
	mkdir -p $(TMP_PATH)

.PHONY: prebuild-check
prebuild-check: $(TMP_PATH) $(INSTALL_PREFIX) 
# Check that all tools where found
ifndef GIT_BIN
	$(error The "$(GIT_BIN_NAME)" executable could not be found in your PATH)
endif
ifndef DEP_BIN
	$(error The "$(DEP_BIN_NAME)" executable could not be found in your PATH)
endif
ifndef GO_BIN
	$(error The "$(GO_BIN_NAME)" executable could not be found in your PATH)
endif

# -------------------------------------------------------------------
# deps
# -------------------------------------------------------------------
$(DEP_BIN_DIR):
	mkdir -p $(DEP_BIN_DIR)

.PHONY: deps 
deps: $(DEP_BIN) $(VENDOR_DIR) ## Download build dependencies.

# install dep in a the tmp/bin dir of the repo
$(DEP_BIN): $(DEP_BIN_DIR) 
	@echo "Installing 'dep' $(DEP_VERSION) at '$(DEP_BIN_DIR)'..."
	mkdir -p $(DEP_BIN_DIR)
ifeq ($(UNAME_S),Darwin)
	@curl -L -s https://github.com/golang/dep/releases/download/$(DEP_VERSION)/dep-darwin-amd64 -o $(DEP_BIN) 
	@cd $(DEP_BIN_DIR) && \
	curl -L -s https://github.com/golang/dep/releases/download/$(DEP_VERSION)/dep-darwin-amd64.sha256 -o $(DEP_BIN_DIR)/dep-darwin-amd64.sha256 && \
	echo "1544afdd4d543574ef8eabed343d683f7211202a65380f8b32035d07ce0c45ef  dep" > dep-darwin-amd64.sha256 && \
	shasum -a 256 --check dep-darwin-amd64.sha256
else
	@curl -L -s https://github.com/golang/dep/releases/download/$(DEP_VERSION)/dep-linux-amd64 -o $(DEP_BIN)
	@cd $(DEP_BIN_DIR) && \
	echo "31144e465e52ffbc0035248a10ddea61a09bf28b00784fd3fdd9882c8cbb2315  dep" > dep-linux-amd64.sha256 && \
	sha256sum -c dep-linux-amd64.sha256
endif
	@chmod +x $(DEP_BIN)

$(VENDOR_DIR): Gopkg.toml
	@echo "checking dependencies with $(DEP_BIN_NAME)"
	@$(DEP_BIN) ensure -v 
		
# -------------------------------------------------------------------
# Code format/check
# -------------------------------------------------------------------
$(GOLINT_BIN):
	cd $(VENDOR_DIR)/github.com/golang/lint/golint && go build -v
$(GOCYCLO_BIN):
	cd $(VENDOR_DIR)/github.com/fzipp/gocyclo && go build -v

GOFORMAT_FILES := $(shell find  . -name '*.go' | grep -vEf .gofmt_exclude)

.PHONY: check-go-format
check-go-format: prebuild-check deps ## Exists with an error if there are files whose formatting differs from gofmt's
	@gofmt -s -l ${GOFORMAT_FILES} 2>&1 \
		| tee /tmp/gofmt-errors \
		| read \
	&& echo "ERROR: These files differ from gofmt's style (run 'make format-go-code' to fix this):" \
	&& cat /tmp/gofmt-errors \
	&& exit 1 \
	|| true

.PHONY: analyze-go-code 
analyze-go-code: deps golint gocyclo govet ## Run a complete static code analysis using the following tools: golint, gocyclo and go-vet.

## Run gocyclo analysis over the code.
golint: $(GOLINT_BIN)
	$(info >>--- RESULTS: GOLINT CODE ANALYSIS ---<<)
	@$(foreach d,$(GOANALYSIS_DIRS),$(GOLINT_BIN) $d 2>&1 | grep -vEf .golint_exclude || true;)

## Run gocyclo analysis over the code.
gocyclo: $(GOCYCLO_BIN)
	$(info >>--- RESULTS: GOCYCLO CODE ANALYSIS ---<<)
	@$(foreach d,$(GOANALYSIS_DIRS),$(GOCYCLO_BIN) -over 10 $d | grep -vEf .golint_exclude || true;)

## Run go vet analysis over the code.
govet:
	$(info >>--- RESULTS: GO VET CODE ANALYSIS ---<<)
	@$(foreach d,$(GOANALYSIS_DIRS),go tool vet --all $d/*.go 2>&1;)

.PHONY: format-go-code
format-go-code: prebuild-check ## Formats any go file that differs from gofmt's style
	@gofmt -s -l -w ${GOFORMAT_FILES}


# -------------------------------------------------------------------
# support for running in dev mode
# -------------------------------------------------------------------
$(FRESH_BIN): $(VENDOR_DIR)
	cd $(VENDOR_DIR)/github.com/pilu/fresh && go build -v

# -------------------------------------------------------------------
# support for generating goa code
# -------------------------------------------------------------------
$(GOAGEN_BIN): $(VENDOR_DIR)
	cd $(VENDOR_DIR)/github.com/goadesign/goa/goagen && go build -v

# -------------------------------------------------------------------
# clean
# -------------------------------------------------------------------

# For the global "clean" target all targets in this variable will be executed
CLEAN_TARGETS =

CLEAN_TARGETS += clean-artifacts
.PHONY: clean-artifacts
## Removes the ./bin directory.
clean-artifacts:
	-rm -rf $(INSTALL_PREFIX)

CLEAN_TARGETS += clean-object-files
.PHONY: clean-object-files
## Runs go clean to remove any executables or other object files.
clean-object-files:
	go clean ./...

CLEAN_TARGETS += clean-generated
.PHONY: clean-generated
## Removes all generated code.
clean-generated:
	-rm -rf ./app
	-rm -rf ./swagger/

CLEAN_TARGETS += clean-vendor
.PHONY: clean-vendor
## Removes the ./vendor directory.
clean-vendor:
	-rm -rf $(VENDOR_DIR)

CLEAN_TARGETS += clean-tmp
.PHONY: clean-tmp
## Removes the ./vendor directory.
clean-tmp:
	-rm -rf $(TMP_DIR)

# Keep this "clean" target here after all `clean-*` sub tasks
.PHONY: clean
clean: $(CLEAN_TARGETS) ## Runs all clean-* targets.

# -------------------------------------------------------------------
# run in dev mode
# -------------------------------------------------------------------
.PHONY: dev
dev: prebuild-check deps generate $(FRESH_BIN) ## run the server locally
	F8_DEVELOPER_MODE_ENABLED=true $(FRESH_BIN)

# -------------------------------------------------------------------
# build the binary executable (to ship in prod)
# -------------------------------------------------------------------
LDFLAGS=-ldflags "-X ${PACKAGE_NAME}/app.Commit=${COMMIT} -X ${PACKAGE_NAME}/app.BuildTime=${BUILD_TIME}"

.PHONY: build
build: prebuild-check deps generate ## Build the server
ifeq ($(OS),Windows_NT)
	go build -v $(LDFLAGS) -o "$(shell cygpath --windows '$(BINARY_SERVER_BIN)')"
else
	go build -v $(LDFLAGS) -o $(BINARY_SERVER_BIN)
endif

.PHONY: generate
generate: prebuild-check $(DESIGNS) $(GOAGEN_BIN) $(VENDOR_DIR) ## Generate GOA sources. Only necessary after clean of if changed `design` folder.
	$(GOAGEN_BIN) app -d ${PACKAGE_NAME}/${DESIGN_DIR}
	$(GOAGEN_BIN) controller -d ${PACKAGE_NAME}/${DESIGN_DIR} -o controller/ --pkg controller --app-pkg ${PACKAGE_NAME}/app
	$(GOAGEN_BIN) gen -d ${PACKAGE_NAME}/${DESIGN_DIR} --pkg-path=github.com/fabric8-services/fabric8-common/goasupport/status --out app
	$(GOAGEN_BIN) gen -d ${PACKAGE_NAME}/${DESIGN_DIR} --pkg-path=github.com/fabric8-services/fabric8-common/goasupport/jsonapi_errors_helpers --out app
	$(GOAGEN_BIN) swagger -d ${PACKAGE_NAME}/${DESIGN_DIR}
	