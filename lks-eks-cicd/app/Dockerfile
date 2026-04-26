# ── Build stage ───────────────────────────────────────────────────────────────
FROM golang:1.23-alpine AS builder
WORKDIR /app

# go mod tidy downloads deps and writes go.sum at build time — no committed go.sum needed
COPY go.mod ./
COPY *.go ./
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server .

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /app/server .
COPY static/ static/

# /app/uploads is an EFS mount target injected by the PVC at runtime
RUN mkdir -p uploads

EXPOSE 8080
ENTRYPOINT ["./server"]
