# ADR 0001: Direct Immich Upload Hostname

Date: 2026-05-23

## Status

Accepted

## Context

Immich is currently exposed through Cloudflare Tunnel. The tunnel forwards the public hostname to Traefik on the node, and Traefik then routes the Immich host to `immich-server`.

This path works for normal access, but large uploads fail before the request reaches Traefik or Immich because Cloudflare applies a request body size limit on proxied traffic. The repo can set a higher origin-side Traefik limit, but that only applies after Cloudflare has accepted the request.

We need uploads up to 1 GiB to work for remote clients without requiring a VPN.

## Decision

Expose a dedicated direct HTTPS hostname for Immich uploads that bypasses Cloudflare proxying and Cloudflare Tunnel.

The direct hostname should be a DNS-only Cloudflare record, for example `photos-direct.lhowsam.com`, pointing at the Hetzner server. It should terminate TLS at Traefik and route to the existing `immich-server` service with the `immich-upload-limit` middleware.

The existing Cloudflare Tunnel hostname can remain the default low-exposure public access path. Large upload clients should use the direct hostname.

## Implementation Notes

- Set Terraform `allow_public_http = true` or otherwise open inbound TCP `80` and `443` to the server.
- Create a DNS-only Cloudflare `A`/`AAAA` record for the direct Immich hostname. Do not enable Cloudflare proxying for this hostname.
- Add TLS termination for direct public traffic, using cert-manager or Traefik ACME.
- Add a Traefik `websecure` route for the direct Immich hostname.
- Attach `immich-upload-limit` to the direct Immich route so Traefik rejects requests above 1 GiB.
- Keep the Cloudflare Tunnel origin route for the existing Immich hostname and other services.
- Configure Immich clients that need large remote uploads to use the direct hostname.

## Consequences

- Remote uploads can exceed Cloudflare's proxied request body limit and be governed by the 1 GiB Traefik origin limit instead.
- The server's public IP becomes reachable on `80`/`443`.
- TLS and certificate renewal become server responsibilities for the direct hostname.
- The direct hostname does not get Cloudflare proxy protections such as WAF and origin IP hiding.
- Traefik host routing, rate limits, security monitoring, and Immich authentication become more important on this path.

## Alternatives Considered

- Upgrade Cloudflare plan: not sufficient for 1 GiB unless using an Enterprise arrangement with a raised limit.
- VPN-only access: safer, but it does not meet the remote-client-without-VPN requirement.
- Split DNS: useful for home Wi-Fi uploads, but it does not solve cellular or remote uploads.
