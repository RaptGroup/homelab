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
FROM alpine:latest

# Install ca-certificates for HTTPS requests
RUN apk --no-cache add ca-certificates

# Create non-root user
RUN adduser -D -s /bin/sh appuser

# Set working directory
WORKDIR /app

# Copy the binary to /usr/local/bin to avoid volume mount conflicts
COPY --from=builder /app/bin/ca-server-linux-amd64 /usr/local/bin/ca-server

# Make binary executable
RUN chmod +x /usr/local/bin/ca-server

# Switch to non-root user
USER appuser

# Expose port (adjust if your app uses a different port)
EXPOSE 8080

# Run the binary
CMD ["/usr/local/bin/ca-server"]
