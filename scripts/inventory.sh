#!/usr/bin/env bash
#
# Inventory cost centers and budgets for a GitHub enterprise.
#
# This exists because `GET .../settings/billing/cost-centers` returns duplicate
# rows: the same ID can appear several times, and the extra copies carry an
# empty name. It is not pagination -- the response has no Link header. The web
# UI inherits the bug and over-reports its active count.
#
# This script deduplicates by ID, preferring the row with a non-empty name, so
# the numbers it prints are the real ones. Use the same approach in any
# automation you build: key off the ID, never the name.
#
# Budgets are genuinely paginated (10 per page), so --paginate is required.
# A naive single-page read makes the budget list look unstable when it is not.
#
# Usage:
#   ./inventory.sh <enterprise-slug> [name-prefix]
#
#   name-prefix   optional; when set, cost centers and their budgets whose name
#                 starts with it are listed separately. Useful in a shared
#                 enterprise to isolate the objects you own.
#
# Requires: gh (authenticated with admin:enterprise), python3
#
# For data residency tenants, set GH_HOST to your subdomain first:
#   export GH_HOST=<subdomain>.ghe.com

set -euo pipefail

ENTERPRISE="${1:-}"
PREFIX="${2:-}"

if [[ -z "$ENTERPRISE" ]]; then
  echo "usage: $0 <enterprise-slug> [name-prefix]" >&2
  exit 1
fi

BASE="/enterprises/${ENTERPRISE}/settings/billing"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gh api "${BASE}/cost-centers"            > "${WORK}/cc.json"
gh api --paginate "${BASE}/budgets"      > "${WORK}/bg.json"

ENTERPRISE="$ENTERPRISE" PREFIX="$PREFIX" WORK="$WORK" python3 <<'PY'
import json, os, collections

work       = os.environ["WORK"]
enterprise = os.environ["ENTERPRISE"]
prefix     = os.environ["PREFIX"]

# ---------------------------------------------------------------- cost centers
rows = json.load(open(f"{work}/cc.json"))["costCenters"]

# Deduplicate by ID. Where an ID appears more than once, keep the row that
# actually has a name -- the duplicates are the ones with name == "".
by_id = {}
for r in rows:
    prev = by_id.get(r["id"])
    if prev is None or (not prev.get("name") and r.get("name")):
        by_id[r["id"]] = r

active  = [c for c in by_id.values() if c.get("state") == "active"]
ghosts  = sum(1 for r in rows if not r.get("name"))

print(f"enterprise : {enterprise}")
print()
print("COST CENTERS")
print(f"  rows returned by the API : {len(rows)}")
print(f"  unique IDs               : {len(by_id)}   <- the real number")
print(f"  blank-name duplicates    : {ghosts}")
print(f"  active (deduplicated)    : {len(active)}")

if len(rows) != len(by_id):
    print("  note: the API over-reports. Always deduplicate by ID.")

mine = [c for c in active if prefix and (c.get("name") or "").startswith(prefix)]
if prefix:
    print()
    print(f"  matching prefix {prefix!r} ({len(mine)}):")
    for c in sorted(mine, key=lambda x: x["name"]):
        res = c.get("resources") or []
        print(f"    {c['name']}")
        print(f"      id        {c['id']}")
        if res:
            names = ", ".join(f"{r['name']} ({r['type']})" for r in res)
            print(f"      resources {len(res)} -> {names}")
        else:
            print(f"      resources 0")

# --------------------------------------------------------------------- budgets
# gh --paginate concatenates JSON objects, so decode them one after another.
raw, budgets, idx = open(f"{work}/bg.json").read(), [], 0
decoder = json.JSONDecoder()
while idx < len(raw):
    while idx < len(raw) and raw[idx].isspace():
        idx += 1
    if idx >= len(raw):
        break
    obj, idx = decoder.raw_decode(raw, idx)
    budgets.extend(obj.get("budgets", []))

ent_scoped = [b for b in budgets if b.get("budget_scope") == "enterprise"]

print()
print("BUDGETS")
print(f"  total       : {len(budgets)}")
print(f"  enterprise-scoped : {len(ent_scoped)}   <- these apply to everyone")

if prefix:
    names = {c["name"] for c in mine}
    ids   = {c["id"] for c in mine}
    owned = [
        b for b in budgets
        if b.get("budget_entity_name") in names or b.get("budget_entity_name") in ids
    ]
    print()
    print(f"  attached to {prefix!r} cost centers ({len(owned)}):")
    for b in owned:
        enforce = "blocks usage" if b.get("prevent_further_usage") else "alert only"
        print(f"    {b.get('budget_product_sku')}  ${b.get('budget_amount')}  [{enforce}]")
        print(f"      id     {b.get('id')}")
        print(f"      scope  {b.get('budget_scope')} -> {b.get('budget_entity_name')}")

print()
print("Web UI:")
print(f"  https://github.com/enterprises/{enterprise}/billing/cost_centers")
print(f"  https://github.com/enterprises/{enterprise}/billing/budgets")
PY
