# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Tests for the checked-in Switchyard observability assets."""

import json
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
ASSETS = REPO_ROOT / "examples" / "prometheus"


def _load_yaml(name: str) -> dict[str, object]:
    """Load an observability YAML asset."""
    return yaml.safe_load((ASSETS / name).read_text(encoding="utf-8"))


def test_local_observability_stack_provisions_all_backends() -> None:
    """Compose binds the metrics, dashboard, and trace services to loopback."""
    compose = _load_yaml("compose.yaml")
    services = compose["services"]

    assert set(services) == {"prometheus", "tempo", "grafana"}
    assert all(
        port.startswith("127.0.0.1:")
        for service in services.values()
        for port in service.get("ports", [])
    )
    assert "host.docker.internal:host-gateway" in services["prometheus"]["extra_hosts"]
    prometheus = _load_yaml("prometheus.yml")
    target = prometheus["scrape_configs"][0]["static_configs"][0]["targets"][0]
    assert target == "host.docker.internal:4000"


def test_grafana_dashboard_uses_provisioned_switchyard_data_sources() -> None:
    """The dashboard queries the checked-in Prometheus data source and links Tempo."""
    datasources = _load_yaml("grafana/provisioning/datasources/datasources.yaml")["datasources"]
    assert {(source["uid"], source["type"]) for source in datasources} == {
        ("switchyard-prometheus", "prometheus"),
        ("switchyard-tempo", "tempo"),
    }

    dashboard = json.loads(
        (ASSETS / "grafana/dashboards/switchyard-routing-overview.json").read_text(
            encoding="utf-8"
        )
    )
    expressions = "\n".join(
        target["expr"] for panel in dashboard["panels"] for target in panel.get("targets", [])
    )

    assert dashboard["uid"] == "switchyard-routing-overview"
    assert "rate(switchyard_total_latency_ms_bucket" in expressions
    assert "rate(switchyard_routing_overhead_ms_bucket" in expressions
    assert "switchyard_client_responses_total" in expressions
    assert "switchyard_model_selections_total" in expressions
    panels = {panel["title"]: panel for panel in dashboard["panels"]}
    assert "Model Selections by Effort (Since Start)" in panels
    selections = panels["Model Selections by Effort (Since Start)"]
    selection_query = selections["targets"][0]["expr"]
    assert "rate(" not in selection_query
    assert " / ignoring(model, effort) group_left " in selection_query
    assert selections["type"] == "bargauge"
    assert selections["options"]["valueMode"] == "text"
    assert selections["options"]["namePlacement"] == "left"
    assert selections["options"]["reduceOptions"]["values"] is True
    # Bars scale to the largest share in view, which only works while the field carries
    # no max: "percent" and "percentunit" make Grafana imply one (100 and 1), which pins
    # every bar to an absolute scale and leaves most of the panel width empty.
    assert "100 * sum by (model, effort)" in selection_query
    assert selections["fieldConfig"]["defaults"]["unit"] == "suffix:%"
    assert "max" not in selections["fieldConfig"]["defaults"]
    # fieldMinMax would compute a per-bar max instead, filling every track completely.
    assert "fieldMinMax" not in selections["fieldConfig"]["defaults"]
    assert selections["gridPos"] == {"h": 8, "w": 16, "x": 8, "y": 28}
    assert "Prompt Cache Hit Rate ($window)" not in panels
    variables = {variable["name"]: variable for variable in dashboard["templating"]["list"]}
    assert set(variables) == {"window", "model", "algorithm", "effort"}
    for name in ("model", "algorithm", "effort"):
        variable = variables[name]
        # Grafana reads the label_values lookup from `query.query`; any other key leaves the
        # variable with no options, and every panel filtered by it renders empty.
        assert variable["query"]["query"] == variable["definition"]
        # "All" must stay a match-everything regex so panels still render before the
        # variable's source metric has any samples.
        assert variable["allValue"] == ".*"
    # Every rate and quantile reads its lookback from the window variable, so a low-traffic
    # deployment can widen it instead of reading empty panels.
    assert variables["window"]["type"] == "interval"
    rate_exprs = [expr for expr in expressions.splitlines() if "rate(" in expr]
    assert rate_exprs
    assert all("[$window]" in expr for expr in rate_exprs)


def test_alert_rules_keep_ratio_denominators_honest() -> None:
    """Ratio alerts divide rates directly and refuse to page on an empty denominator."""
    groups = _load_yaml("switchyard.rules.yaml")["groups"]
    rules = {rule["alert"]: rule for group in groups for rule in group["rules"]}

    assert set(rules) == {
        "RouterOverheadHigh",
        "RouterOverheadShareHigh",
        "RouterErrorRateNotReducing",
    }

    # A clamped denominator rewrites the ratio at low request rates, which is exactly
    # when an error-rate alert has to be trustworthy.
    for rule in rules.values():
        assert "clamp_min" not in rule["expr"]

    # Dividing by a zero denominator yields +Inf, which clears any threshold, so the
    # share alert has to require that something was actually measured.
    share = rules["RouterOverheadShareHigh"]["expr"]
    assert "sum(rate(switchyard_total_latency_ms_count[15m])) > 0" in share

    # Comparing two ratios off a handful of responses is noise, not evidence.
    assert "sum(increase(switchyard_client_responses_total[15m])) >= 10" in (
        rules["RouterErrorRateNotReducing"]["expr"]
    )

    # Aggregating a passthrough algorithm and a classifier-backed one into one
    # histogram yields a quantile that describes neither.
    assert "sum by (algorithm, le)" in rules["RouterOverheadHigh"]["expr"]


def test_tempo_accepts_otlp_http_from_a_host_server() -> None:
    """Tempo listens on the OTLP/HTTP endpoint documented for Switchyard."""
    tempo = _load_yaml("tempo.yaml")
    otlp_http = tempo["distributor"]["receivers"]["otlp"]["protocols"]["http"]

    assert otlp_http["endpoint"] == "0.0.0.0:4318"
