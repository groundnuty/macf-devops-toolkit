# Remote-agent OTLP setup

How to send observability data from agents running off the cluster VM
(operator's laptop, agents on the old VM, future remote testers) to the
monitoring VM's central-collector. Updated 2026-06-17 for the DR-004 native-k3s
migration.

## TL;DR — no setup needed anymore

On native k3s the cluster's LoadBalancer Services (`central-collector-lb`,
`tempo-query-lb`, …) bind their ports on **every** host interface — private IP,
localhost, AND the tailnet interface — via klipper/iptables. So a remote agent
just points at the monitoring VM's stable Tailscale FQDN + the **native** port:

```
MACF_OTEL_ENDPOINT="http://orzech-dev-agents-monitoring.tail491af.ts.net:4318"
```

That's it. No `tailscale serve`, no port-forward, no `0.0.0.0` binding. (The old
k3d setup needed `tailscale serve` because k3d's serverlb bound only to
`127.0.0.1`; native k3s does not — see "What changed" below.)

## Endpoints (monitoring VM)

Reach by the **Tailscale FQDN**, not the LAN IP (`192.168.102.15` is
DHCP-mutable; MagicDNS is stable):

| Signal | Endpoint |
|---|---|
| OTLP HTTP | `http://orzech-dev-agents-monitoring.tail491af.ts.net:4318/v1/traces` |
| OTLP gRPC | `orzech-dev-agents-monitoring.tail491af.ts.net:4317` |
| Tempo query | `http://orzech-dev-agents-monitoring.tail491af.ts.net:3200` |

Find the canonical FQDN on the monitoring VM:

```bash
tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//'
```

## Laptop / remote-agent side

Bake the endpoint into the agent launcher when generating/refreshing it:

```bash
MACF_OTEL_ENDPOINT="http://orzech-dev-agents-monitoring.tail491af.ts.net:4318" \
  macf update --plugin --yes
```

Or per-launch override (no `macf update`):

```bash
OTEL_EXPORTER_OTLP_ENDPOINT="http://orzech-dev-agents-monitoring.tail491af.ts.net:4318" \
  ./claude.sh
```

For agents whose workspace carries a `.claude/settings.local.json`, set
`env.MACF_OTEL_ENDPOINT` there and relaunch the agent's tmux session (the
endpoint is baked into the process env at launch — a running agent won't pick up
a config change until relaunch).

## Smoke verification (from the remote host)

```bash
curl -i -X POST \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"laptop-smoke"}}]},"scopeSpans":[{"scope":{"name":"smoke"},"spans":[{"traceId":"01020304050607080102030405060708","spanId":"0102030405060708","name":"laptop-smoke","startTimeUnixNano":"'$(date +%s%N)'","endTimeUnixNano":"'$(($(date +%s%N) + 1000000))'","kind":1}]}]}]}' \
  http://orzech-dev-agents-monitoring.tail491af.ts.net:4318/v1/traces
```

Expected: `HTTP/1.1 200 OK` + `{"partialSuccess":{}}`.

Confirm it landed (Tempo is also reachable on the FQDN — no port-forward):

```bash
curl -G "http://orzech-dev-agents-monitoring.tail491af.ts.net:3200/api/search" \
  --data-urlencode "tags=service.name=laptop-smoke" --data-urlencode "limit=3" \
  | jq '.traces[] | {traceID, rootServiceName}'
```

Note: Langfuse OTel ingestion is async (collector → S3/MinIO → worker →
ClickHouse), so a trace can take ~30s to appear in Langfuse even though Tempo
shows it immediately.

## Security model

- **Native LoadBalancer exposure** binds on all interfaces *including* the
  cloud subnet interface (`ens3`). The monitoring VM is on a private subnet;
  gate external access at the subnet/firewall + Tailnet ACL layers as needed.
- **Tailnet ACLs** gate tailnet access; **Tailscale-internal encryption**
  protects node-to-node traffic.
- If localhost-only OTLP exposure is ever required (as the old k3d setup had),
  that would need a deliberate bind override — native ServiceLB does not do it.

## What changed (DR-004)

The old k3d VM bound OTLP to `127.0.0.1` only, so cross-host (tailnet) access
required `tailscale serve` proxying (devops#69) and `+10000` offset ports to
avoid a same-VM compose-stack collision. The new dedicated monitoring VM runs
native k3s — ServiceLB binds the native ports on all interfaces directly, and
there is no compose stack — so both the `tailscale serve` layer and the port
offset are gone. The `make tailscale-otlp-up/down` targets + their hack scripts
were removed in #100.

## Related

- `CLAUDE.md` § "Cluster topology + standard endpoints" — source of truth
- `design/DR-004-migrate-to-native-k3s-with-etcd-backups.md`
- `groundnuty/macf-devops-toolkit#101` (this sweep), `#69` (the retired k3d-era design)
