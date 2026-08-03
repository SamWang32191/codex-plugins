#!/usr/bin/env python3

import argparse
import datetime as dt
import decimal
import hashlib
import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple


DEFAULT_BASE_URL = "https://support.softleader.com.tw/backend/"
DEFAULT_CONFIG_PATH = (
    pathlib.Path.home()
    / ".config"
    / "softleader"
    / "agent-skills"
    / "daily-reports"
    / "config.json"
)
TIMEOUT_SECONDS = 20
REPORT_TYPES = {"COMPANY", "PROJECT", "RD", "OTHER", "LEAVE"}
ROOT_FIELDS = {"reportDate", "details"}
DETAIL_FIELDS = {
    "id",
    "reportType",
    "projectId",
    "projectModuleId",
    "mandateCharterId",
    "modifiedTime",
    "hours",
    "subject",
    "description",
    "todos",
}
PROJECT_CONFIG_FIELDS = {"id", "code", "label"}


class DailyReportsError(Exception):
    def __init__(
        self, reason: str, message: str, details: Optional[Dict[str, Any]] = None
    ) -> None:
        super().__init__(message)
        self.reason = reason
        self.message = message
        self.details = details or {}


def emit(payload: Dict[str, Any], stream: Any = sys.stdout) -> None:
    json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
    stream.write("\n")


def emit_ready(data: Any) -> None:
    emit({"status": True, "data": data})


def emit_error(error: DailyReportsError) -> None:
    emit(
        {
            "status": False,
            "reason": error.reason,
            "message": error.message,
            "details": error.details,
        },
        sys.stderr,
    )


def normalize_base_url(value: str) -> str:
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise DailyReportsError(
            "invalid_base_url", "baseUrl must be an absolute HTTP(S) URL."
        )
    return value.rstrip("/") + "/"


def normalize_config_projects(value: Any) -> List[Dict[str, Any]]:
    """Validate and normalize the optional local project option cache.

    The cache deliberately uses the same display fields as the Personal API
    option object, except for ``value`` which is always derived from ``id``.
    This keeps the config small while preventing arbitrary project-list data
    from being mistaken for a valid option response.
    """
    if not isinstance(value, list):
        raise DailyReportsError(
            "invalid_config", "projects must be an array when present."
        )

    normalized: List[Dict[str, Any]] = []
    seen_ids: Set[int] = set()
    for index, project in enumerate(value):
        location = f"projects[{index}]"
        if not isinstance(project, dict):
            raise DailyReportsError("invalid_config", f"{location} must be an object.")
        unknown = sorted(set(project) - PROJECT_CONFIG_FIELDS)
        missing = sorted(PROJECT_CONFIG_FIELDS - set(project))
        if unknown or missing:
            details: Dict[str, Any] = {"path": location}
            if unknown:
                details["unknownFields"] = unknown
            if missing:
                details["missingFields"] = missing
            raise DailyReportsError(
                "invalid_config",
                f"{location} must contain only id, code, and label.",
                details,
            )

        project_id = project["id"]
        if isinstance(project_id, bool) or not isinstance(project_id, int) or project_id <= 0:
            raise DailyReportsError(
                "invalid_config", f"{location}.id must be a positive integer."
            )
        if project_id in seen_ids:
            raise DailyReportsError(
                "invalid_config",
                "projects must not contain duplicate ids.",
                {"projectId": project_id},
            )

        code = project["code"]
        if code is not None and (not isinstance(code, str) or not code.strip()):
            raise DailyReportsError(
                "invalid_config",
                f"{location}.code must be a non-empty string or null.",
            )
        label = project["label"]
        if not isinstance(label, str) or not label.strip():
            raise DailyReportsError(
                "invalid_config", f"{location}.label must be a non-empty string."
            )

        seen_ids.add(project_id)
        normalized.append({"id": project_id, "code": code, "label": label})
    return normalized


def configured_projects(config: Dict[str, Any]) -> Optional[List[Dict[str, Any]]]:
    """Return a non-empty configured project cache, if present.

    A missing key or an explicitly empty list means that no local source is
    configured and permits the live endpoint.  Malformed values are still
    rejected by ``normalize_config_projects`` rather than silently falling
    back.
    """
    if "projects" not in config:
        return None
    projects = normalize_config_projects(config["projects"])
    return projects or None


def project_options_from_config(config: Dict[str, Any]) -> Optional[List[Dict[str, Any]]]:
    projects = configured_projects(config)
    if projects is None:
        return None
    return [
        {
            "id": project["id"],
            "value": str(project["id"]),
            "code": project["code"],
            "label": project["label"],
        }
        for project in projects
    ]


def load_config(path: pathlib.Path) -> Dict[str, Any]:
    if not path.is_file():
        raise DailyReportsError(
            "missing_config",
            "Create the Daily Reports config before calling the API.",
            {"path": str(path)},
        )
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DailyReportsError(
            "invalid_config", "Daily Reports config is not valid JSON.", {"path": str(path)}
        ) from exc
    if not isinstance(raw, dict):
        raise DailyReportsError("invalid_config", "Config root must be a JSON object.")
    token = raw.get("apiToken")
    if not isinstance(token, str) or not token.strip():
        raise DailyReportsError(
            "missing_api_token",
            "Config must contain a non-empty apiToken.",
            {"path": str(path)},
        )
    base_url = raw.get("baseUrl", DEFAULT_BASE_URL)
    if not isinstance(base_url, str):
        raise DailyReportsError("invalid_config", "baseUrl must be a string when present.")
    config = {
        "apiToken": token.strip(),
        "baseUrl": normalize_base_url(base_url),
        "path": str(path),
    }
    if "projects" in raw:
        config["projects"] = normalize_config_projects(raw["projects"])
    return config


def build_url(base_url: str, endpoint: str, query: Optional[Dict[str, str]] = None) -> str:
    url = urllib.parse.urljoin(base_url, endpoint.lstrip("/"))
    if query:
        url += "?" + urllib.parse.urlencode(query)
    return url


def request_json(
    config: Dict[str, Any],
    endpoint: str,
    query: Optional[Dict[str, str]] = None,
    payload: Optional[Dict[str, Any]] = None,
) -> Any:
    url = build_url(config["baseUrl"], endpoint, query)
    headers = {"X-API-KEY": config["apiToken"], "Accept": "application/json"}
    body = None
    method = "GET"
    if payload is not None:
        method = "POST"
        headers["Content-Type"] = "application/json"
        body = canonical_json(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            response_body: Any = json.loads(raw)
        except json.JSONDecodeError:
            response_body = raw[:1000]
        reason = {
            400: "bad_request",
            401: "unauthorized",
            403: "forbidden",
            404: "not_found",
        }.get(exc.code, "http_error")
        raise DailyReportsError(
            reason,
            "ERP Daily Reports API returned an HTTP error.",
            {"httpStatus": exc.code, "url": url, "body": response_body},
        ) from exc
    except urllib.error.URLError as exc:
        raise DailyReportsError(
            "connection_failed", "Unable to connect to ERP Daily Reports API.", {"url": url}
        ) from exc
    except json.JSONDecodeError as exc:
        raise DailyReportsError(
            "invalid_json_response", "ERP response was not valid JSON.", {"url": url}
        ) from exc


def canonical_json(payload: Dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def confirmation_code(payload: Dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()[:12]


def read_payload(path_value: str) -> Dict[str, Any]:
    try:
        raw = sys.stdin.read() if path_value == "-" else pathlib.Path(path_value).read_text(encoding="utf-8")
        payload = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise DailyReportsError(
            "invalid_payload", "Input must be a readable JSON document.", {"input": path_value}
        ) from exc
    if not isinstance(payload, dict):
        raise DailyReportsError("invalid_payload", "Payload root must be a JSON object.")
    return payload


def require_fields_only(value: Dict[str, Any], allowed: Set[str], location: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise DailyReportsError(
            "invalid_payload", f"Unknown fields at {location}.", {"fields": unknown}
        )


def require_positive_id(value: Any, location: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise DailyReportsError("invalid_payload", f"{location} must be a positive integer.")


def optional_text(detail: Dict[str, Any], field: str, maximum: int, index: int) -> str:
    value = detail.get(field, "")
    if value is None:
        return ""
    if not isinstance(value, str):
        raise DailyReportsError(
            "invalid_payload", f"details[{index}].{field} must be a string when present."
        )
    if len(value) > maximum:
        raise DailyReportsError(
            "invalid_payload", f"details[{index}].{field} exceeds {maximum} characters."
        )
    return value


def parse_hours(value: Any, index: int) -> decimal.Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise DailyReportsError(
            "invalid_payload", f"details[{index}].hours must be a JSON number."
        )
    try:
        hours = decimal.Decimal(str(value))
    except decimal.InvalidOperation as exc:
        raise DailyReportsError(
            "invalid_payload", f"details[{index}].hours must be numeric."
        ) from exc
    if not hours.is_finite() or hours < 0 or hours > 9999:
        raise DailyReportsError(
            "invalid_payload", f"details[{index}].hours must be between 0 and 9999."
        )
    fraction_digits = max(0, -hours.as_tuple().exponent)
    if fraction_digits > 2:
        raise DailyReportsError(
            "invalid_payload", f"details[{index}].hours supports at most 2 decimal places."
        )
    return hours


def validate_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    require_fields_only(payload, ROOT_FIELDS, "root")
    report_date = payload.get("reportDate")
    if not isinstance(report_date, str):
        raise DailyReportsError("invalid_payload", "reportDate is required as YYYY-MM-DD.")
    try:
        dt.date.fromisoformat(report_date)
    except ValueError as exc:
        raise DailyReportsError("invalid_payload", "reportDate must use YYYY-MM-DD.") from exc
    details = payload.get("details")
    if not isinstance(details, list) or not details:
        raise DailyReportsError("invalid_payload", "details must contain at least one item.")

    total_hours = decimal.Decimal("0")
    update_count = 0
    seen_projects: Set[Tuple[int, Optional[int]]] = set()
    seen_rd: Set[Optional[int]] = set()
    for index, detail in enumerate(details):
        if not isinstance(detail, dict):
            raise DailyReportsError("invalid_payload", f"details[{index}] must be an object.")
        require_fields_only(detail, DETAIL_FIELDS, f"details[{index}]")
        report_type = detail.get("reportType")
        if report_type not in REPORT_TYPES:
            raise DailyReportsError(
                "invalid_payload",
                f"details[{index}].reportType must be one of {sorted(REPORT_TYPES)}.",
            )
        detail_id = detail.get("id")
        if detail_id is not None:
            require_positive_id(detail_id, f"details[{index}].id")
            update_count += 1
        modified_time = detail.get("modifiedTime")
        if modified_time is not None:
            if detail_id is None:
                raise DailyReportsError(
                    "invalid_payload", f"details[{index}].modifiedTime requires id."
                )
            if not isinstance(modified_time, str):
                raise DailyReportsError(
                    "invalid_payload", f"details[{index}].modifiedTime must be a string."
                )
            try:
                dt.datetime.strptime(modified_time, "%Y-%m-%dT%H:%M:%S")
            except ValueError as exc:
                raise DailyReportsError(
                    "invalid_payload",
                    f"details[{index}].modifiedTime must use YYYY-MM-DDTHH:mm:ss.",
                ) from exc

        hours = parse_hours(detail.get("hours"), index)
        total_hours += hours
        subject = detail.get("subject")
        if not isinstance(subject, str) or not subject:
            raise DailyReportsError(
                "invalid_payload", f"details[{index}].subject must be a non-empty string."
            )
        if len(subject) > 100:
            raise DailyReportsError(
                "invalid_payload", f"details[{index}].subject exceeds 100 characters."
            )
        description = optional_text(detail, "description", 900, index)
        optional_text(detail, "todos", 900, index)
        normalized_description = description.lstrip("\r\n")
        combined_length = len(subject) + (1 + len(normalized_description) if normalized_description else 0)
        if combined_length > 1000:
            raise DailyReportsError(
                "invalid_payload",
                f"details[{index}] subject and description exceed 1000 characters combined.",
            )

        project_id = detail.get("projectId")
        module_id = detail.get("projectModuleId")
        charter_id = detail.get("mandateCharterId")
        for field, value in (
            ("projectId", project_id),
            ("projectModuleId", module_id),
            ("mandateCharterId", charter_id),
        ):
            if value is not None:
                require_positive_id(value, f"details[{index}].{field}")

        if report_type == "PROJECT":
            if project_id is None:
                raise DailyReportsError(
                    "invalid_payload", f"details[{index}].projectId is required for PROJECT."
                )
            if charter_id is not None:
                raise DailyReportsError(
                    "invalid_payload", f"details[{index}] PROJECT must omit mandateCharterId."
                )
            key = (project_id, module_id)
            if key in seen_projects:
                raise DailyReportsError(
                    "invalid_payload", "Duplicate PROJECT + module entries must be merged."
                )
            seen_projects.add(key)
        elif report_type == "RD":
            if project_id is not None or module_id is not None:
                raise DailyReportsError(
                    "invalid_payload", f"details[{index}] RD must omit project references."
                )
            if charter_id in seen_rd:
                raise DailyReportsError(
                    "invalid_payload", "Duplicate RD mandate-charter entries must be merged."
                )
            seen_rd.add(charter_id)
        elif project_id is not None or module_id is not None or charter_id is not None:
            raise DailyReportsError(
                "invalid_payload",
                f"details[{index}] {report_type} must omit project and mandate-charter references.",
            )

    return {
        "reportDate": report_date,
        "detailCount": len(details),
        "createCount": len(details) - update_count,
        "updateCount": update_count,
        "totalHours": format(total_hours, "f"),
    }


def option_ids(options: Any, endpoint: str) -> Set[int]:
    if not isinstance(options, list):
        raise DailyReportsError(
            "invalid_api_response", "Option endpoint did not return an array.", {"endpoint": endpoint}
        )
    return {
        item["id"]
        for item in options
        if isinstance(item, dict) and isinstance(item.get("id"), int)
    }


def remote_validate(config: Dict[str, Any], payload: Dict[str, Any]) -> List[str]:
    report_date = payload["reportDate"]
    used_configured_projects = False
    report_type_endpoint = "/personal-api/daily-reports/options/report-types"
    type_options = request_json(config, report_type_endpoint)
    if not isinstance(type_options, list):
        raise DailyReportsError(
            "invalid_api_response",
            "Report type endpoint did not return an array.",
            {"endpoint": report_type_endpoint},
        )
    allowed_types = {
        item.get("value")
        for item in type_options
        if isinstance(item, dict) and isinstance(item.get("value"), str)
    }
    requested_types = {detail["reportType"] for detail in payload["details"]}
    if not requested_types.issubset(allowed_types):
        raise DailyReportsError(
            "invalid_reference",
            "Payload contains report types unavailable to this API key.",
            {"unavailable": sorted(requested_types - allowed_types)},
        )

    project_details = [d for d in payload["details"] if d["reportType"] == "PROJECT"]
    if project_details:
        project_endpoint = "/personal-api/daily-reports/options/projects"
        configured = configured_projects(config)
        if configured is None:
            project_options = request_json(
                config, project_endpoint, {"reportDate": report_date}
            )
            project_ids = option_ids(project_options, project_endpoint)
        else:
            used_configured_projects = True
            project_ids = {project["id"] for project in configured}
        unavailable_projects = sorted(
            {d["projectId"] for d in project_details} - project_ids
        )
        if unavailable_projects:
            raise DailyReportsError(
                "invalid_reference",
                "Payload contains projects unavailable on reportDate.",
                {"projectIds": unavailable_projects, "reportDate": report_date},
            )
        for project_id in sorted({d["projectId"] for d in project_details}):
            module_endpoint = (
                f"/personal-api/daily-reports/options/projects/{project_id}/modules"
            )
            module_options = request_json(
                config, module_endpoint, {"reportDate": report_date}
            )
            module_ids = option_ids(module_options, module_endpoint)
            for detail in [d for d in project_details if d["projectId"] == project_id]:
                module_id = detail.get("projectModuleId")
                hours = decimal.Decimal(str(detail["hours"]))
                if module_ids and hours > 0 and module_id is None:
                    raise DailyReportsError(
                        "invalid_reference",
                        "A project with modules requires projectModuleId when hours are positive.",
                        {"projectId": project_id},
                    )
                if module_id is not None and module_id not in module_ids:
                    raise DailyReportsError(
                        "invalid_reference",
                        "Payload contains a module unavailable for its project.",
                        {"projectId": project_id, "projectModuleId": module_id},
                    )

    charter_ids = {
        d["mandateCharterId"]
        for d in payload["details"]
        if d["reportType"] == "RD" and d.get("mandateCharterId") is not None
    }
    if charter_ids:
        charter_endpoint = "/personal-api/daily-reports/options/mandate-charters"
        charter_options = request_json(config, charter_endpoint)
        unavailable_charters = sorted(charter_ids - option_ids(charter_options, charter_endpoint))
        if unavailable_charters:
            raise DailyReportsError(
                "invalid_reference",
                "Payload contains mandate charters unavailable to this API key.",
                {"mandateCharterIds": unavailable_charters},
            )

    warnings = [
        "Personal API cannot read existing daily reports; cross-existing duplicate entries and complete daily total hours remain unknown."
    ]
    if used_configured_projects:
        warnings.append(
            "Configured project list was not live-validated for API key owner or reportDate; POST may still reject the project reference."
        )
    return warnings


def cmd_precheck(args: argparse.Namespace) -> None:
    config_path = pathlib.Path(args.config).expanduser()
    try:
        config = load_config(config_path)
        probe = request_json(config, "/personal-api/probe")
        emit(
            {
                "status": True,
                "ready": True,
                "config": {
                    "path": config["path"],
                    "baseUrl": config["baseUrl"],
                    "apiTokenPresent": True,
                },
                "api": probe,
            }
        )
    except DailyReportsError as error:
        emit(
            {
                "status": False,
                "ready": False,
                "reason": error.reason,
                "message": error.message,
                "details": error.details,
                "config": {"path": str(config_path)},
            }
        )


def cmd_options(args: argparse.Namespace) -> None:
    config = load_config(pathlib.Path(args.config).expanduser())
    if args.option_kind == "report-types":
        endpoint = "/personal-api/daily-reports/options/report-types"
        query = None
    elif args.option_kind == "projects":
        configured = project_options_from_config(config)
        if configured is not None:
            emit_ready(configured)
            return
        endpoint = "/personal-api/daily-reports/options/projects"
        query = {"reportDate": args.report_date} if args.report_date else None
    elif args.option_kind == "modules":
        endpoint = f"/personal-api/daily-reports/options/projects/{args.project_id}/modules"
        query = {"reportDate": args.report_date} if args.report_date else None
    else:
        endpoint = "/personal-api/daily-reports/options/mandate-charters"
        query = None
    emit_ready(request_json(config, endpoint, query))


def preview_data(payload: Dict[str, Any], summary: Dict[str, Any], warnings: Iterable[str]) -> Dict[str, Any]:
    return {
        "payload": payload,
        "summary": summary,
        "warnings": list(warnings),
        "confirmationCode": confirmation_code(payload),
        "submitted": False,
    }


def cmd_preview(args: argparse.Namespace) -> None:
    payload = read_payload(args.input)
    summary = validate_payload(payload)
    emit_ready(preview_data(payload, summary, []))


def cmd_preflight(args: argparse.Namespace) -> None:
    payload = read_payload(args.input)
    summary = validate_payload(payload)
    config = load_config(pathlib.Path(args.config).expanduser())
    warnings = remote_validate(config, payload)
    emit_ready(preview_data(payload, summary, warnings))


def cmd_submit(args: argparse.Namespace) -> None:
    payload = read_payload(args.input)
    summary = validate_payload(payload)
    expected_code = confirmation_code(payload)
    if args.confirm != expected_code:
        raise DailyReportsError(
            "confirmation_mismatch",
            "Confirmation code does not match the exact payload. Run preflight again.",
            {"expectedConfirmationCode": expected_code},
        )
    if summary["updateCount"] and not args.allow_updates:
        raise DailyReportsError(
            "updates_not_allowed",
            "Payload contains existing detail IDs; pass --allow-updates only after explicit update confirmation.",
            {"updateCount": summary["updateCount"]},
        )
    config = load_config(pathlib.Path(args.config).expanduser())
    remote_validate(config, payload)
    response = request_json(config, "/personal-api/daily-reports", payload=payload)
    emit(
        {
            "status": True,
            "submitted": True,
            "confirmationCode": expected_code,
            "summary": summary,
            "response": response,
        }
    )


def add_config_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="SoftLeader ERP Daily Reports Personal API client")
    subparsers = parser.add_subparsers(dest="command", required=True)

    precheck = subparsers.add_parser("precheck")
    add_config_argument(precheck)
    precheck.set_defaults(func=cmd_precheck)

    options = subparsers.add_parser("options")
    add_config_argument(options)
    option_subparsers = options.add_subparsers(dest="option_kind", required=True)
    report_types = option_subparsers.add_parser("report-types")
    report_types.set_defaults(func=cmd_options)
    projects = option_subparsers.add_parser("projects")
    projects.add_argument("--report-date")
    projects.set_defaults(func=cmd_options)
    modules = option_subparsers.add_parser("modules")
    modules.add_argument("--project-id", type=int, required=True)
    modules.add_argument("--report-date")
    modules.set_defaults(func=cmd_options)
    mandate_charters = option_subparsers.add_parser("mandate-charters")
    mandate_charters.set_defaults(func=cmd_options)

    preview = subparsers.add_parser("preview")
    preview.add_argument("--input", required=True, help="Payload JSON path, or - for stdin")
    preview.set_defaults(func=cmd_preview)

    preflight = subparsers.add_parser("preflight")
    add_config_argument(preflight)
    preflight.add_argument("--input", required=True, help="Payload JSON path, or - for stdin")
    preflight.set_defaults(func=cmd_preflight)

    submit = subparsers.add_parser("submit")
    add_config_argument(submit)
    submit.add_argument("--input", required=True, help="Payload JSON path, or - for stdin")
    submit.add_argument("--confirm", required=True)
    submit.add_argument("--allow-updates", action="store_true")
    submit.set_defaults(func=cmd_submit)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except DailyReportsError as error:
        emit_error(error)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
