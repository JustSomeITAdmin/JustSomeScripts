"""Microsoft Graph client for resolving Intune app GUIDs to display names.

Two auth modes, chosen by what's configured:
  * app-only (client credentials) when GRAPH_CLIENT_SECRET is set — unattended,
    needs the DeviceManagementApps.Read.All *application* permission + consent.
  * device-code (delegated) when only tenant + client id are set — no secret to
    store; the admin signs in once and the token is cached locally.

msal/requests are imported lazily so the rest of the tool runs without them.
"""

from __future__ import annotations

from typing import Any

from rca import config

GRAPH_BASE = "https://graph.microsoft.com/v1.0"
# ManagedDevices/Configuration scopes power the config-profile state enrichment;
# adding a scope invalidates cached silent tokens once (browser re-consent).
_DELEGATED_SCOPES = ["DeviceManagementApps.Read.All",
                     "DeviceManagementManagedDevices.Read.All",
                     "DeviceManagementConfiguration.Read.All"]
_APP_SCOPES = ["https://graph.microsoft.com/.default"]


class GraphNotConfigured(Exception):
    """Raised when no usable Graph credentials are present."""


def auth_mode() -> str:
    """Always returns a usable mode.

    'app-only' when a client secret is configured; otherwise 'delegated', which
    works with no app registration via the well-known public client (interactive
    browser or device code).
    """
    if config.GRAPH_TENANT_ID and config.GRAPH_CLIENT_ID and config.GRAPH_CLIENT_SECRET:
        return "app-only"
    return "delegated"


def get_token(interactive: bool = True, device_code_prompt=print) -> str:
    """Acquire a Graph access token.

    Delegated auth needs no app registration: it falls back to the well-known
    Microsoft public client and the 'organizations' authority, so a browser
    sign-in (interactive=True) or device code chooses the tenant + identity.
    """
    try:
        import msal
    except ImportError as exc:  # pragma: no cover
        raise GraphNotConfigured("msal not installed (pip install -e .)") from exc

    if auth_mode() == "app-only":
        authority = f"https://login.microsoftonline.com/{config.GRAPH_TENANT_ID}"
        app = msal.ConfidentialClientApplication(
            config.GRAPH_CLIENT_ID, authority=authority,
            client_credential=config.GRAPH_CLIENT_SECRET,
        )
        result = app.acquire_token_for_client(scopes=_APP_SCOPES)
        if "access_token" not in result:
            raise GraphNotConfigured(
                result.get("error_description") or result.get("error") or "token failed"
            )
        return result["access_token"]

    # Delegated: use configured client/tenant if present, else well-known + organizations.
    client_id = config.GRAPH_CLIENT_ID or config.WELLKNOWN_PUBLIC_CLIENT_ID
    tenant = config.GRAPH_TENANT_ID or "organizations"
    authority = f"https://login.microsoftonline.com/{tenant}"

    cache = msal.SerializableTokenCache()
    if config.MSAL_CACHE_PATH.exists():
        cache.deserialize(config.MSAL_CACHE_PATH.read_text())
    app = msal.PublicClientApplication(client_id, authority=authority, token_cache=cache)

    result = None
    accounts = app.get_accounts()
    if accounts:
        result = app.acquire_token_silent(_DELEGATED_SCOPES, account=accounts[0])
    if not result:
        if interactive:
            result = app.acquire_token_interactive(
                scopes=_DELEGATED_SCOPES, prompt="select_account"
            )
        else:
            flow = app.initiate_device_flow(scopes=_DELEGATED_SCOPES)
            if "user_code" not in flow:
                raise GraphNotConfigured(f"device flow failed: {flow.get('error_description')}")
            device_code_prompt(flow["message"])
            result = app.acquire_token_by_device_flow(flow)

    if cache.has_state_changed:
        config.ensure_dirs()
        config.MSAL_CACHE_PATH.write_text(cache.serialize())

    if "access_token" not in result:
        raise GraphNotConfigured(
            result.get("error_description") or result.get("error") or "token acquisition failed"
        )
    return result["access_token"]


def whoami(token: str) -> str | None:
    """Return the signed-in user's UPN (delegated), or None (e.g. app-only)."""
    import requests

    r = requests.get(
        f"{GRAPH_BASE}/me",
        headers={"Authorization": f"Bearer {token}"},
        params={"$select": "userPrincipalName,displayName"},
        timeout=30,
    )
    if r.status_code != 200:
        return None
    d = r.json()
    return d.get("userPrincipalName") or d.get("displayName")


def _shape(d: dict) -> dict[str, Any]:
    return {
        "display_name": d.get("displayName"),
        "publisher": d.get("publisher"),
        "app_type": (d.get("@odata.type") or "").replace("#microsoft.graph.", "") or None,
    }


def resolve_app(token: str, app_id: str) -> dict[str, Any] | None:
    """Fetch one mobileApp. Returns dict(display_name, publisher, app_type) or None (404)."""
    import requests

    r = requests.get(
        f"{GRAPH_BASE}/deviceAppManagement/mobileApps/{app_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return _shape(r.json())


def get_health_script(token: str, script_id: str) -> dict | None:
    """Proactive remediation (deviceHealthScript) name + publisher + assignments.

    Beta endpoint. Assignments are flattened to 'type:GroupName (schedule)'
    strings — enough to answer "is my script still assigned, and to whom".
    None on 404.
    """
    import requests

    base = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts"
    hdr = {"Authorization": f"Bearer {token}"}
    r = requests.get(f"{base}/{script_id}", headers=hdr, timeout=30)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    d = r.json()
    targets = []
    a = requests.get(f"{base}/{script_id}/assignments", headers=hdr, timeout=30)
    for x in (a.json().get("value", []) if a.ok else []):
        t = x.get("target") or {}
        ty = t.get("@odata.type", "").split(".")[-1].replace("AssignmentTarget", "")
        gid = t.get("groupId")
        name = ""
        if gid:
            g = requests.get(f"{GRAPH_BASE}/groups/{gid}?$select=displayName",
                             headers=hdr, timeout=30)
            name = g.json().get("displayName", gid) if g.ok else gid
        sched = (x.get("runSchedule") or {}).get("@odata.type", "").split(".")[-1]
        sched = sched.replace("deviceHealthScript", "").replace("Schedule", "")
        targets.append(f"{ty}:{name or 'all'}" + (f" ({sched})" if sched else ""))
    return {"displayName": d.get("displayName"), "publisher": d.get("publisher"),
            "assignments": "; ".join(targets) or "(none)"}


def get_app_raw(token: str, app_id: str) -> dict | None:
    """Fetch the full mobileApp object (incl. detectionRules/rules). None on 404.

    $expand=categories is harmless; detectionRules/rules are returned inline on
    the win32LobApp type without an expand.
    """
    import requests

    r = requests.get(
        f"{GRAPH_BASE}/deviceAppManagement/mobileApps/{app_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.json()


def get_managed_device(token: str, device_name: str) -> dict | None:
    """Find the Intune managedDevice by name (most recently synced on duplicates)."""
    import requests

    safe = device_name.replace("'", "''")
    r = requests.get(
        f"{GRAPH_BASE}/deviceManagement/managedDevices",
        headers={"Authorization": f"Bearer {token}"},
        params={"$filter": f"deviceName eq '{safe}'",
                "$select": "id,deviceName,lastSyncDateTime"},
        timeout=30,
    )
    r.raise_for_status()
    devices = r.json().get("value", [])
    if not devices:
        return None
    return max(devices, key=lambda d: d.get("lastSyncDateTime") or "")


def get_config_states(token: str, managed_device_id: str) -> list[dict]:
    """Per-profile assignment states for a device (classic/template/OMA-URI profiles).

    ponytail: v1.0 deviceConfigurationStates doesn't cover Settings Catalog
    policies — those need the beta getConfigurationPoliciesReportForDevice
    report. Add when name-resolution for settings-catalog profiles matters.
    """
    import requests

    r = requests.get(
        f"{GRAPH_BASE}/deviceManagement/managedDevices/{managed_device_id}/deviceConfigurationStates",
        headers={"Authorization": f"Bearer {token}"},
        timeout=60,
    )
    r.raise_for_status()
    return r.json().get("value", [])


_SC_STATUS = {1: "notApplicable", 2: "compliant", 3: "remediated",
              4: "nonCompliant", 5: "error", 6: "conflict"}


def get_settings_catalog_report(token: str, managed_device_id: str) -> list[dict]:
    """Settings Catalog policy states for a device (beta report endpoint).

    v1.0 deviceConfigurationStates only covers classic profiles; Settings
    Catalog status lives behind this report POST.
    """
    import requests

    # The endpoint 400s without this exact select/filter shape (matches what the
    # Intune admin center sends); PolicyBaseTypeName filter is required.
    base_types = ("Microsoft.Management.Services.Api.DeviceConfiguration",
                  "DeviceManagementConfigurationPolicy",
                  "DeviceConfigurationAdmxPolicy",
                  "Microsoft.Management.Services.Api.DeviceManagementIntent")
    type_filter = " or ".join(f"(PolicyBaseTypeName eq '{t}')" for t in base_types)
    r = requests.post(
        "https://graph.microsoft.com/beta/deviceManagement/reports/"
        "getConfigurationPoliciesReportForDevice",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"select": ["IntuneDeviceId", "PolicyBaseTypeName", "PolicyId", "PolicyStatus",
                         "UPN", "UserId", "PspdpuLastModifiedTimeUtc", "PolicyName",
                         "UnifiedPolicyType"],
              "filter": f"({type_filter}) and (IntuneDeviceId eq '{managed_device_id}')",
              "skip": 0, "top": 100, "orderBy": ["PolicyName"]},
        timeout=60,
    )
    r.raise_for_status()
    d = r.json()
    cols = [c["Column"] for c in d.get("Schema", [])]
    out = []
    for row in d.get("Values", []):
        rec = dict(zip(cols, row))
        out.append({
            "id": rec.get("PolicyId"),
            "displayName": rec.get("PolicyName"),
            "platformType": rec.get("UnifiedPolicyType") or "settingsCatalog",
            "state": _SC_STATUS.get(rec.get("PolicyStatus"), str(rec.get("PolicyStatus"))),
            "userPrincipalName": rec.get("UPN"),
        })
    return out


def get_setting_states(token: str, managed_device_id: str, state_id: str) -> list[dict]:
    """Per-setting states for one profile on one device."""
    import requests

    r = requests.get(
        f"{GRAPH_BASE}/deviceManagement/managedDevices/{managed_device_id}"
        f"/deviceConfigurationStates/{state_id}/settingStates",
        headers={"Authorization": f"Bearer {token}"},
        timeout=60,
    )
    r.raise_for_status()
    return r.json().get("value", [])


# Graph caps a $batch at 20 sub-requests.
BATCH_SIZE = 20


def resolve_batch(token: str, app_ids: list[str]) -> dict[str, dict | None]:
    """Resolve up to BATCH_SIZE app ids in one Graph $batch call.

    Returns {app_id: info_dict | None}. None means 404 (deleted/unknown app);
    app_ids missing from the result hit a non-404 error (e.g. throttling).
    """
    import requests

    reqs = [{"id": str(i), "method": "GET",
             "url": f"/deviceAppManagement/mobileApps/{aid}"}
            for i, aid in enumerate(app_ids)]
    r = requests.post(
        f"{GRAPH_BASE}/$batch",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"requests": reqs},
        timeout=60,
    )
    r.raise_for_status()
    out: dict[str, dict | None] = {}
    for resp in r.json().get("responses", []):
        aid = app_ids[int(resp["id"])]
        status = resp.get("status")
        if status == 200:
            out[aid] = _shape(resp.get("body", {}))
        elif status == 404:
            out[aid] = None
        # other statuses (429/5xx): leave unset so the caller can count as error
    return out
