#!/usr/bin/env python3
"""
Apply Grafana Alerting rules from gpu-node-alerts.yaml via the Grafana
provisioning API. Idempotent (POST then on-conflict-PUT).

Usage:
    ./apply.py
        # default transport: kubectl exec into the Grafana pod, curl localhost
    ./apply.py --grafana-url http://localhost:3000
        # direct HTTP, e.g. after:
        #   kubectl -n observability port-forward svc/prometheus-stack-grafana 3000:80

The script does, in order:
    1. Read gpu-node-alerts.yaml — a high-level rule format (`query`,
       `condition: {type, value}` where type is 'gt' or 'lt', ONLY those
       two; optional per-rule `noDataState`, default "OK") — much simpler
       than the Grafana native rule format
    2. Create the destination folder (idempotent)
    3. Create or update each alert rule, building the Grafana-native JSON
       (refid'd queries + threshold expression + relative time range)
    4. REPLACE the notification policy tree with a single root routing to
       --receiver-name — see the SHARP EDGE comment at step [3] in main()

Exits non-zero if any rule fails to POST/PUT.

Anonymous-admin access to Grafana is enabled in helm values
(auth.anonymous.org_role=Admin), so no auth token is required on either
transport.
"""
import argparse, json, subprocess, sys
from pathlib import Path

import yaml  # PyYAML — `pip install pyyaml` if missing


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("yaml_file", nargs="?",
                   default=str(Path(__file__).parent / "gpu-node-alerts.yaml"))
    p.add_argument("--grafana-url",
                   help="Direct base URL, e.g. http://localhost:3000 after "
                        "`kubectl -n observability port-forward "
                        "svc/prometheus-stack-grafana 3000:80`. "
                        "Default transport: kubectl exec into the Grafana pod.")
    p.add_argument("--kubectl-namespace", default="observability")
    p.add_argument("--datasource-uid", default="prometheus",
                   help="Grafana DS UID for Prometheus")
    p.add_argument("--receiver-name", default="Kai Evans",
                   help="Existing contact-point to route to (notification policy root)")
    return p.parse_args()


def grafana_call(args, method: str, path: str, body=None) -> dict:
    """Call Grafana API either via kubectl exec or direct HTTP."""
    body_json = json.dumps(body) if body is not None else ""
    headers = [
        "-H", "X-WEBAUTH-USER: admin",
        "-H", "Content-Type: application/json",
        "-H", "X-Disable-Provenance: true",  # so the resources can be edited in UI too
    ]
    if args.grafana_url:
        cmd = ["curl", "-sS", "-w", "\n%{http_code}", "-X", method,
               *headers, args.grafana_url.rstrip("/") + path]
        if body is not None:
            cmd += ["-d", body_json]
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    else:
        # kubectl exec into Grafana pod and curl from localhost
        url = f"http://localhost:3000{path}"
        inner = ["curl", "-sS", "-w", "\n%{http_code}", "-X", method, *headers, url]
        if body is not None:
            inner += ["-d", body_json]
        cmd = ["kubectl", "-n", args.kubectl_namespace, "exec",
               "deployment/prometheus-stack-grafana", "-c", "grafana",
               "--"] + inner
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    out = result.stdout.rstrip()
    if "\n" in out:
        body_str, status = out.rsplit("\n", 1)
    else:
        body_str, status = "", out
    return {"status": int(status) if status.isdigit() else 0,
            "body": body_str.strip()}


def build_rule_payload(spec: dict, group_name: str, folder_uid: str,
                       ds_uid: str) -> dict:
    """Convert our high-level rule spec → Grafana native rule JSON."""
    cond = spec["condition"]
    cond_type = cond["type"]  # 'gt' | 'lt' — the only supported types
    threshold = cond["value"]

    # Grafana's threshold-expression model
    threshold_model = {
        "refId": "C",
        "type": "threshold",
        "expression": "A",
        "conditions": [{
            "evaluator": {"params": [threshold], "type": cond_type},
            "operator": {"type": "and"},
            "query": {"params": ["A"]},
            "reducer": {"params": [], "type": "last"},
            "type": "query",
        }],
        "datasource": {"type": "__expr__", "uid": "__expr__"},
    }
    query_model = {
        "refId": "A",
        "expr": spec["query"],
        "intervalMs": 1000,
        "maxDataPoints": 43200,
        "instant": True,
    }
    return {
        "uid": spec["uid"],
        "title": spec["title"],
        "ruleGroup": group_name,
        "folderUID": folder_uid,
        "condition": "C",
        "data": [
            {
                "refId": "A",
                "datasourceUid": ds_uid,
                "queryType": "",
                "relativeTimeRange": {"from": 600, "to": 0},
                "model": query_model,
            },
            {
                "refId": "C",
                "datasourceUid": "__expr__",
                "queryType": "",
                "relativeTimeRange": {"from": 0, "to": 0},
                "model": threshold_model,
            },
        ],
        # Default OK: the box sleeps by design — most of a typical week
        # there are no metrics at all, and NoData would spam the root
        # policy on every suspend. Override per-rule in the YAML if needed.
        "noDataState": spec.get("noDataState", "OK"),
        "execErrState": "Error",
        "for": spec.get("for", "5m"),
        "labels": {"severity": spec["severity"]},
        "annotations": {
            "summary": spec.get("summary", ""),
            "description": spec.get("description", ""),
        },
    }


def main() -> int:
    args = parse_args()
    spec = yaml.safe_load(Path(args.yaml_file).read_text())

    folder = spec["folder"]
    group = spec["group"]
    rules = spec["rules"]

    # 1. Create/ensure folder.
    print(f"[1] ensuring folder uid={folder['uid']!r}")
    r = grafana_call(args, "POST", "/api/folders",
                     {"uid": folder["uid"], "title": folder["title"]})
    if r["status"] in (200, 201):
        print(f"    created (HTTP {r['status']})")
    elif r["status"] in (409, 412):
        print(f"    already exists (HTTP {r['status']}) — ok")
    else:
        print(f"    !! HTTP {r['status']}: {r['body'][:300]}")
        return 1

    # 2. Apply each rule.
    print(f"[2] applying {len(rules)} alert rule(s) to group "
          f"{group['name']!r} in folder {folder['uid']!r}")
    failed = 0
    for rule in rules:
        payload = build_rule_payload(rule, group["name"], folder["uid"],
                                      args.datasource_uid)
        # POST creates; if it exists, switch to PUT.
        r = grafana_call(args, "POST", "/api/v1/provisioning/alert-rules",
                         payload)
        if r["status"] in (200, 201):
            print(f"    + {rule['uid']:<28} created")
            continue
        if r["status"] in (409, 412):
            r2 = grafana_call(args, "PUT",
                              f"/api/v1/provisioning/alert-rules/{rule['uid']}",
                              payload)
            if r2["status"] in (200, 202):
                print(f"    ~ {rule['uid']:<28} updated")
            else:
                print(f"    !! {rule['uid']}: PUT HTTP {r2['status']}: "
                      f"{r2['body'][:300]}")
                failed += 1
        else:
            print(f"    !! {rule['uid']}: POST HTTP {r['status']}: "
                  f"{r['body'][:300]}")
            failed += 1

    # 3. Point alert routing at the named contact point.
    #
    # !!! SHARP EDGE: this PUT REPLACES the ENTIRE notification policy tree
    # with the single root route below. Any nested routes or mute timings
    # added in the Grafana UI get wiped. Acceptable for this single-receiver
    # homelab; a proper read-modify-write (GET /api/v1/provisioning/policies,
    # patch, PUT back) is a TODO before anything beyond the root route
    # exists.
    print(f"[3] updating notification policy root receiver to "
          f"{args.receiver_name!r} (replaces the whole policy tree)")
    new_policy = {
        "receiver": args.receiver_name,
        "group_by": ["grafana_folder", "alertname"],
        "group_wait": "30s",
        "group_interval": "5m",
        "repeat_interval": "4h",
    }
    r = grafana_call(args, "PUT", "/api/v1/provisioning/policies", new_policy)
    if r["status"] in (200, 202):
        print(f"    updated (HTTP {r['status']})")
    else:
        print(f"    !! HTTP {r['status']}: {r['body'][:300]}")

    print()
    if failed:
        print(f"Done with {failed} FAILED rule(s) — see !! lines above.")
        return 1
    print("Done. Verify in Grafana → Alerting → Alert rules.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
