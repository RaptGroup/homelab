# build stage
FROM golang:1.24.4-alpine AS builder

RUN apk add --no-cache make

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

# Build the Linux AMD64 binary
RUN make build-linux

# Runtime stage
FROM scratch

# Set working directory
WORKDIR /app

# Copy the binary to /usr/local/bin to avoid volume mount conflicts
COPY --from=builder --chmod=755 /app/bin/distributor-linux-amd64 /usr/local/bin/distributor

# Run the binary
CMD ["/usr/local/bin/distributor"]
