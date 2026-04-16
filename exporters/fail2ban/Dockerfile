FROM golang:1.25-bookworm AS build
WORKDIR /src

ARG TARGETOS=linux
ARG TARGETARCH=amd64

COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /out/fail2ban-security-exporter ./cmd/fail2ban-security-exporter

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates fail2ban \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/fail2ban-security-exporter /usr/local/bin/fail2ban-security-exporter

EXPOSE 9191
ENTRYPOINT ["/usr/local/bin/fail2ban-security-exporter"]
