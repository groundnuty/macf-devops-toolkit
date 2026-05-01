# Remote-agent OTLP setup

How to send observability data from agents running off the cluster VM
(operator's laptop, future remote testers) to the cluster's
central-collector. Verified live 2026-05-01.

## Why this exists

The cluster's k3d port-mappings bind OTLP endpoints (`:14317`/`:14318`)
to `127.0.0.1` only on the VM. Tailscale-routed traffic on the VM's
`tailscale0` interface never reaches a localhost-bound listener.

Three alternatives were considered for cross-host access:

| Approach | Trade-off | Verdict |
|---|---|---|
| `0.0.0.0` k3d binding | exposes OTLP on `ens3` (cloud subnet, default route to internet); VM not alone on subnet | rejected |
| Tailscale-IP-pinned k3d binding | works but pins to specific Tailscale IP that may rotate post `tailscale logout` | rejected — fragility |
| **`tailscale serve`** | listens on tailnet interface specifically, MagicDNS-stable, ACL-gated | **chosen** (devops-toolkit#69) |

## Operator-side: enable on the VM

One-time on the VM:

```bash
cd environments/macf
make tailscale-otlp-up
```

Persists across `tailscaled` restarts via Tailscale's own state.
Idempotent — re-running resets + reconfigures.

To tear down:

```bash
make tailscale-otlp-down
```

### Sudo handling

`tailscale serve` writes require root. The make target auto-detects:

- If `tailscale set --operator=$USER` was set (one-time, on the VM):
  no sudo prompt
- Otherwise: falls back to `sudo` (interactive prompt)

Recommended one-time setup for passwordless flow:

```bash
sudo tailscale set --operator=$USER
```

### Verification on the VM

```bash
tailscale serve status
```

Expected output (4 ports):

```
|-- tcp://orzech-dev-agents.<tailnet>.ts.net:14317 (TLS over TCP, tailnet only)
|-- tcp://orzech-dev-agents.<tailnet>.ts.net:14318 (TLS over TCP, tailnet only)
|-- tcp://orzech-dev-agents.<tailnet>.ts.net:4317  (TLS over TCP, tailnet only)
|-- tcp://orzech-dev-agents.<tailnet>.ts.net:4318  (TLS over TCP, tailnet only)
```

The `(TLS over TCP)` annotation is about Tailscale's internal tunnel
encryption, NOT a user-facing TLS handshake. Clients send **plain HTTP**
to those hostnames over the Tailscale-encrypted tunnel — verified via
`curl -X POST http://orzech-dev-agents.<tailnet>.ts.net:14318/v1/traces`
returning HTTP 200.

## Laptop-side: bake the tailnet endpoint into claude.sh

When generating or refreshing the agent launcher on the laptop:

```bash
MACF_OTEL_ENDPOINT="http://orzech-dev-agents.<tailnet>.ts.net:14318" \
  macf update --plugin --yes
```

Use the **MagicDNS hostname**, not the Tailscale IP. The hostname is
DNS-stable across IP rotations.

To find the canonical hostname, on the VM:

```bash
tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//'
```

Returns e.g. `orzech-dev-agents.tail491af.ts.net`.

Per-launch override (no `macf update`) instead of template-time bake:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT="http://orzech-dev-agents.<tailnet>.ts.net:14318" \
  ./claude.sh
```

## Smoke verification (from the laptop)

```bash
curl -i -X POST \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"laptop-smoke"}}]},"scopeSpans":[{"scope":{"name":"smoke"},"spans":[{"traceId":"01020304050607080102030405060708","spanId":"0102030405060708","name":"laptop-smoke","startTimeUnixNano":"'$(date +%s%N)'","endTimeUnixNano":"'$(($(date +%s%N) + 1000000))'","kind":1}]}]}]}' \
  http://orzech-dev-agents.<tailnet>.ts.net:14318/v1/traces
```

Expected: `HTTP/1.1 200 OK` + `{"partialSuccess":{}}`.

To confirm the trace landed in Tempo (run on the VM with port-forward):

```bash
kubectl -n tempo port-forward svc/tempo 13200:3200 &
curl -G "http://127.0.0.1:13200/api/search" \
  --data-urlencode "tags=service.name=laptop-smoke" --data-urlencode "limit=3" \
  | jq '.traces[] | {traceID, rootServiceName}'
```

## Security model

- **No 0.0.0.0 binding** — OTLP ports stay localhost-only on the VM
- **No public exposure** — `tailscale serve` is tailnet-only; `funnel`
  would be the public variant (not used here)
- **Tailnet ACLs** gate access on top of the network-layer scoping —
  configurable in Tailscale admin
- **Tailscale-internal encryption** between nodes — `(TLS over TCP)`
  annotation refers to this

## Related

- `environments/macf/hack/tailscale-otlp-up.sh` — script source
- `environments/macf/hack/tailscale-otlp-down.sh` — teardown
- `environments/Makefile` — `tailscale-otlp-up` / `tailscale-otlp-down`
  targets
- `groundnuty/macf-devops-toolkit#69` — design + landing PR
