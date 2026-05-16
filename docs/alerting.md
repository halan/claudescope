# Alerting

claudescope ships Grafana-provisioned alert rules that watch the Prometheus metrics emitted by Claude Code and the correlator sidecar.

## What's shipped

| Rule | UID | Default threshold |
|---|---|---|
| Daily cost cap exceeded | `claudescope-daily-cost-cap` | $10 / 24h |
| Expensive single session | `claudescope-expensive-session` | $5 / session / 1h |
| API error spike | `claudescope-error-spike` | > 0.1 api_error/sec for 10m |

All alerts land in the `claudescope` folder under Alerting → Alert rules.

## Routing

By default every alert routes to a single contact point named **`claudescope-default`**, defined in `grafana/provisioning/alerting/contact-points.yaml`. It ships as a webhook pointing at `http://localhost:9999/alerts-placeholder` — a non-existent endpoint, so out of the box you'll see alerts fire in Grafana's UI but no external delivery.

To get notifications somewhere real, edit `grafana/provisioning/alerting/contact-points.yaml` and either:

- swap the webhook `url` for your Slack/Discord/Teams/PagerDuty endpoint, or
- replace the receiver with a different `type` (e.g. `email`, `slack`, `discord`, `pagerduty`) and the matching `settings` block — see Grafana's [contact-points reference](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/manage-contact-points/).

Then `docker restart claude-grafana`. Provisioning re-applies on every Grafana start.

## Tuning a threshold

Each rule file lives under `grafana/provisioning/alerting/`. Open the relevant file, change the `params: [N]` value inside the threshold expression (refId `B`), and restart Grafana.

For the daily cost cap:

```yaml
# grafana/provisioning/alerting/rules-cost.yaml
conditions:
  - type: query
    evaluator:
      type: gt
      params: [10]   # ← change this
```

## Silencing

For one-off silences (e.g. you're knowingly running a long bulk job), use the Grafana Alerting UI: **Alerting → Silences → New silence**. Provisioned silences are also possible via `grafana/provisioning/alerting/silences.yaml` if you need them in source control.
