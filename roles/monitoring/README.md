# `monitoring`

**Phase 7 · Implemented**

Prometheus, node_exporter, and Grafana.

## One role, two jobs

The role checks group membership and does the right thing, so there is one role
rather than three:

| Group | Installs | Hosts |
|---|---|---|
| `monitored` | node_exporter | all three |
| `monitoring` | Prometheus + Grafana | server3 |

Keeping the collector **off** the web and database hosts is deliberate:
monitoring should survive the failure it exists to report.

## Targets come from the inventory

```yaml
prometheus_scrape_targets: "{{ groups['monitored'] | default([]) }}"
```

Never hand-listed. A server added to the inventory but forgotten in a target
list is a server nobody is watching, and that gap does not announce itself.

Instance labels are rewritten from `10.0.0.12:9100` to `server2`, so graphs and
alerts read in host names.

## node_exporter is not bound to 0.0.0.0

It publishes a detailed inventory of the host — kernel version, every
filesystem, every listening port, every systemd unit and its state — with **no
authentication**. On a competition network that is a reconnaissance gift.

Bound to the private address, and the firewall rule in `group_vars/monitored`
narrows it further to the monitoring host alone.

The **systemd collector is enabled**, which is what makes the `ServiceDown`
alert possible. mdadm, infiniband, nfs and nfsd are disabled — none of that
hardware exists and each logs an error per scrape.

## Retention has two caps, on purpose

```
--storage.tsdb.retention.time=30d
--storage.tsdb.retention.size=8GB
```

Time alone does not bound disk: add an exporter and 30 days of ten times the
data is ten times the disk. Size alone would keep data indefinitely on a quiet
system.

server3 also holds every backup. A monitoring system that fills the disk it
shares with the backups is worse than no monitoring system.

**These are command-line flags, not `prometheus.yml` settings** — set in
`/etc/default/prometheus`. Looking for a retention setting in the config file is
a well-worn dead end.

## Alerts

Every rule has a `for:` clause. Without one a single scrape blip fires an alert,
and an alert that cries wolf is worse than none because people learn to ignore
the channel it arrives on.

| Alert | Fires when | Severity |
|---|---|---|
| `HostDown` | No successful scrape for 2m | critical |
| `DiskSpaceLow` | Above 85% for 10m | warning |
| `DiskFillingFast` | Linear prediction hits zero within 4h | critical |
| `MemoryHigh` | Above 90% for 10m | warning |
| `SwapActive` | Over half of swap used for 15m | warning |
| `LoadHigh` | 15-min load > 2× cores | warning |
| `ServiceDown` | A named unit inactive for 3m | critical |
| `ServiceFlapping` | >4 state changes in 15m | warning |
| `CertificateExpiringSoon` | Within 21 days | warning |

Two worth explaining:

**`DiskFillingFast`** uses `predict_linear` rather than a threshold. A threshold
tells you it is 85% full; it does not tell you whether that took a month or an
hour. Four hours of warning is enough to act during an event.

**`MemoryHigh`** uses `MemAvailable`, not `MemFree`. Linux uses free memory for
cache, so `MemFree` is near zero on a healthy server — alerting on it would mean
alerting always.

`CertificateExpiringSoon` **cannot fire yet**: it needs the blackbox exporter,
which is not deployed. It is written so the alert exists the moment the metric
does. Until then the `cron` role checks expiry daily and mails the result.

Alertmanager is not deployed. Rules still evaluate and show as **FIRING** in the
Prometheus UI under Alerts — enough for a club that watches a dashboard. Wire it
up when someone will actually be paged.

## Grafana and the third-party repository

Grafana is not in Debian, so this adds **the only third-party APT source in the
repository**.

The key goes to `/etc/apt/keyrings` — not the deprecated `apt-key`, where a key
can sign *any* repository — and the source is scoped with `signed-by=` so it can
install Grafana packages and nothing else. It cannot silently take over a Debian
package name.

Recorded in [decisions.md](../../docs/decisions.md). A security club should know
exactly where every package on its servers comes from.

If you would rather not carry that source, set `grafana_enabled: false`.
Prometheus has a usable built-in UI and its own alert view.

## Provisioning, not clicking

The datasource is a file. Anything configured only through the web interface is
lost the moment the host is reinstalled — and this repository exists so that
reinstalling is cheap. The datasource is marked `editable: false`, because
Ansible owns the file and a UI edit would be silently overwritten.

## Variables

| Variable | Default |
|---|---|
| `node_exporter_bind` | private address |
| `node_exporter_port` | `9100` |
| `prometheus_retention_time` / `_size` | `30d` / `8GB` |
| `prometheus_scrape_interval` | `30s` |
| `prometheus_scrape_targets` | the `monitored` group |
| `prometheus_alert_disk_percent` | `85` |
| `grafana_enabled` | `true` |
| `grafana_anonymous_access` | `false` |
| `grafana_analytics_enabled` | `false` |

## Tags

`monitoring`, `node-exporter`, `prometheus`, `grafana`, `packages`, `config`,
`alerts`, `service`, `verify`

## Verifying

```bash
sudo promtool check config /etc/prometheus/prometheus.yml
sudo promtool check rules /etc/prometheus/rules/jengasec.yml
curl -s localhost:9090/api/v1/targets | python3 -m json.tool | grep -E 'health|instance'
curl -s localhost:9100/metrics | head
curl -s localhost:3000/api/health
```

The targets query is the one that matters: any target reporting `down` means
node_exporter is not running there, or the firewall rule in
`group_vars/monitored` is not letting the monitoring host through. The role
reports this at the end of every run.

Then open Grafana at `http://server3:3000`, sign in as `admin` with the vault
password, and confirm the Prometheus datasource shows as working.
