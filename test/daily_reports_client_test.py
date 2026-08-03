import argparse
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[1]
CLIENT_PATH = (
    REPOSITORY_ROOT
    / "plugins"
    / "daily-reports"
    / "skills"
    / "daily-reports"
    / "scripts"
    / "daily_reports.py"
)
OPENAI_YAML_PATH = (
    REPOSITORY_ROOT
    / "plugins"
    / "daily-reports"
    / "skills"
    / "daily-reports"
    / "agents"
    / "openai.yaml"
)
SPEC = importlib.util.spec_from_file_location("daily_reports", CLIENT_PATH)
daily_reports = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(daily_reports)


def project_payload():
    return {
        "reportDate": "2026-08-03",
        "details": [
            {
                "reportType": "PROJECT",
                "projectId": 701,
                "projectModuleId": 801,
                "hours": 2,
                "subject": "完成 Daily Reports Plugin",
                "description": "實作 API client 與安全確認流程",
                "todos": "補齊驗證",
            }
        ],
    }


class DailyReportsClientTest(unittest.TestCase):
    def test_skill_requires_explicit_invocation(self):
        openai_yaml = OPENAI_YAML_PATH.read_text(encoding="utf-8")

        self.assertIn(
            "policy:\n  allow_implicit_invocation: false\n", openai_yaml
        )

    def test_valid_payload_returns_summary_and_stable_confirmation_code(self):
        payload = project_payload()

        summary = daily_reports.validate_payload(payload)

        self.assertEqual(summary["detailCount"], 1)
        self.assertEqual(summary["createCount"], 1)
        self.assertEqual(summary["updateCount"], 0)
        self.assertEqual(summary["totalHours"], "2")
        self.assertEqual(
            daily_reports.confirmation_code(payload),
            daily_reports.confirmation_code(json.loads(json.dumps(payload))),
        )

    def test_duplicate_project_and_module_is_rejected(self):
        payload = project_payload()
        payload["details"].append(dict(payload["details"][0]))

        with self.assertRaisesRegex(
            daily_reports.DailyReportsError, "Duplicate PROJECT"
        ):
            daily_reports.validate_payload(payload)

    def test_non_project_reference_is_rejected(self):
        payload = project_payload()
        payload["details"][0].update(
            {"reportType": "OTHER", "projectId": 701, "projectModuleId": None}
        )

        with self.assertRaisesRegex(
            daily_reports.DailyReportsError, "must omit project"
        ):
            daily_reports.validate_payload(payload)

    def test_hours_string_is_rejected(self):
        payload = project_payload()
        payload["details"][0]["hours"] = "2"

        with self.assertRaisesRegex(
            daily_reports.DailyReportsError, "JSON number"
        ):
            daily_reports.validate_payload(payload)

    def test_remote_preflight_checks_report_type_project_and_module(self):
        payload = project_payload()
        responses = [
            [{"value": "PROJECT"}],
            [{"id": 701}],
            [{"id": 801}],
        ]

        with mock.patch.object(
            daily_reports, "request_json", side_effect=responses
        ) as request_json:
            warnings = daily_reports.remote_validate({}, payload)

        self.assertEqual(request_json.call_count, 3)
        self.assertEqual(len(warnings), 1)

    def test_configured_projects_are_normalized_to_options_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = pathlib.Path(directory) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "apiToken": "token-must-not-be-emitted",
                        "projects": [
                            {"id": 701, "code": "P-701", "label": "專案A"},
                        ],
                    }
                ),
                encoding="utf-8",
            )

            config = daily_reports.load_config(config_path)
            self.assertEqual(
                daily_reports.project_options_from_config(config),
                [
                    {
                        "id": 701,
                        "value": "701",
                        "code": "P-701",
                        "label": "專案A",
                    }
                ],
            )
            self.assertNotIn("apiToken", daily_reports.project_options_from_config(config)[0])

    def test_invalid_project_config_is_rejected_without_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = pathlib.Path(directory) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "apiToken": "token-must-not-be-emitted",
                        "projects": [{"id": 701, "code": "P-701", "label": "專案A", "value": "701"}],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                daily_reports.DailyReportsError, "only id, code, and label"
            ) as context:
                daily_reports.load_config(config_path)

        self.assertEqual(context.exception.reason, "invalid_config")
        self.assertNotIn("token-must-not-be-emitted", context.exception.message)

    def test_options_projects_uses_configured_projects_without_api_call(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = pathlib.Path(directory) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "apiToken": "token-must-not-be-emitted",
                        "projects": [{"id": 701, "code": "P-701", "label": "專案A"}],
                    }
                ),
                encoding="utf-8",
            )
            args = argparse.Namespace(
                option_kind="projects",
                report_date="2026-08-03",
                project_id=None,
                config=str(config_path),
            )

            with mock.patch.object(daily_reports, "request_json") as request_json:
                with mock.patch.object(daily_reports, "emit") as emit:
                    daily_reports.cmd_options(args)

        request_json.assert_not_called()
        result = emit.call_args.args[0]
        self.assertEqual(result["status"], True)
        self.assertEqual(result["data"][0]["value"], "701")
        self.assertNotIn("token-must-not-be-emitted", repr(result))

    def test_options_projects_empty_config_calls_projects_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = pathlib.Path(directory) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "apiToken": "token-must-not-be-emitted",
                        "projects": [],
                    }
                ),
                encoding="utf-8",
            )
            args = argparse.Namespace(
                option_kind="projects",
                report_date="2026-08-03",
                project_id=None,
                config=str(config_path),
            )
            with mock.patch.object(
                daily_reports,
                "request_json",
                return_value=[{"id": 701, "value": "701", "code": "P-701", "label": "專案A"}],
            ) as request_json:
                with mock.patch.object(daily_reports, "emit") as emit:
                    daily_reports.cmd_options(args)

        request_json.assert_called_once_with(
            mock.ANY,
            "/personal-api/daily-reports/options/projects",
            {"reportDate": "2026-08-03"},
        )
        self.assertEqual(emit.call_args.args[0]["data"][0]["id"], 701)

    def test_empty_project_config_falls_back_to_projects_endpoint(self):
        payload = project_payload()
        config = {"projects": []}
        responses = [
            [{"value": "PROJECT"}],
            [{"id": 701}],
            [{"id": 801}],
        ]

        with mock.patch.object(
            daily_reports, "request_json", side_effect=responses
        ) as request_json:
            warnings = daily_reports.remote_validate(config, payload)

        self.assertEqual(request_json.call_count, 3)
        self.assertEqual(request_json.call_args_list[1].args[1], "/personal-api/daily-reports/options/projects")
        self.assertEqual(len(warnings), 1)

    def test_remote_preflight_uses_non_empty_configured_project_ids(self):
        payload = project_payload()
        config = {
            "projects": [{"id": 701, "code": "P-701", "label": "專案A"}],
        }
        responses = [
            [{"value": "PROJECT"}],
            [{"id": 801}],
        ]

        with mock.patch.object(
            daily_reports, "request_json", side_effect=responses
        ) as request_json:
            warnings = daily_reports.remote_validate(config, payload)

        self.assertEqual(request_json.call_count, 2)
        self.assertEqual(
            request_json.call_args_list[1].args[1],
            "/personal-api/daily-reports/options/projects/701/modules",
        )
        self.assertEqual(len(warnings), 2)
        self.assertEqual(
            warnings[1],
            "Configured project list was not live-validated for API key owner or reportDate; POST may still reject the project reference.",
        )

    def test_submit_rejects_confirmation_mismatch_before_api_call(self):
        payload = project_payload()
        with tempfile.TemporaryDirectory() as directory:
            payload_path = pathlib.Path(directory) / "payload.json"
            payload_path.write_text(json.dumps(payload), encoding="utf-8")
            args = argparse.Namespace(
                input=str(payload_path),
                confirm="wrong-code",
                allow_updates=False,
                config="unused.json",
            )

            with mock.patch.object(daily_reports, "request_json") as request_json:
                with self.assertRaisesRegex(
                    daily_reports.DailyReportsError, "Confirmation code"
                ):
                    daily_reports.cmd_submit(args)

        request_json.assert_not_called()

    def test_update_requires_explicit_allow_updates(self):
        payload = project_payload()
        payload["details"][0]["id"] = 123
        with tempfile.TemporaryDirectory() as directory:
            payload_path = pathlib.Path(directory) / "payload.json"
            payload_path.write_text(json.dumps(payload), encoding="utf-8")
            args = argparse.Namespace(
                input=str(payload_path),
                confirm=daily_reports.confirmation_code(payload),
                allow_updates=False,
                config="unused.json",
            )

            with mock.patch.object(daily_reports, "request_json") as request_json:
                with self.assertRaisesRegex(
                    daily_reports.DailyReportsError, "--allow-updates"
                ):
                    daily_reports.cmd_submit(args)

        request_json.assert_not_called()


if __name__ == "__main__":
    unittest.main()
