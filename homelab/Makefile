# Variables
CA_BINARY_NAME=ca-server
MODULE_NAME=github.com/haljac/homelab
CA_SERVER_PATH=./cmd/ca-server
BUILD_DIR=bin

# Default target
.PHONY: all
all: clean build-linux build-darwin

# Clean build directory
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)

# Build for Linux AMD64
.PHONY: build-linux
build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BUILD_DIR)/$(CA_BINARY_NAME)-linux-amd64 $(CA_SERVER_PATH)

# Build for macOS Apple Silicon (ARM64)
.PHONY: build-darwin
build-darwin:
	GOOS=darwin GOARCH=arm64 go build -o $(BUILD_DIR)/$(CA_BINARY_NAME)-darwin-arm64 $(CA_SERVER_PATH)

# Build for current platform
.PHONY: build
build:
	go build -o $(BUILD_DIR)/$(CA_BINARY_NAME) $(CA_SERVER_PATH)

# Install dependencies
.PHONY: deps
deps:
	go mod tidy
	go mod download

# Run tests
.PHONY: test
test:
	go test ./...

# Run the application (current platform build)
.PHONY: run-ca-server
run-ca-server: build
	./$(BUILD_DIR)/$(CA_BINARY_NAME)

# Format code
.PHONY: fmt
fmt:
	go fmt ./...

# Vet code
.PHONY: vet
vet:
	go vet ./...

# Lint code (requires golangci-lint)
.PHONY: lint
lint:
	golangci-lint run

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all         - Build for both Linux AMD64 and macOS ARM64"
	@echo "  build       - Build for current platform"
	@echo "  build-linux - Build for Linux AMD64"
	@echo "  build-darwin- Build for macOS Apple Silicon (ARM64)"
	@echo "  clean       - Clean build directory"
	@echo "  deps        - Install dependencies"
	@echo "  test        - Run tests"
	@echo "  run         - Build and run the application"
	@echo "  fmt         - Format code"
	@echo "  vet         - Vet code"
	@echo "  lint        - Lint code (requires golangci-lint)"
	@echo "  help        - Show this help message"
