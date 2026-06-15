import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


class SummarizeOutputTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo_root = Path(__file__).resolve().parents[1]
        self.script_path = self.repo_root / "Scripts" / "summarize.py"
        self.input_path = self.root / "meeting_整理版.md"
        self.input_path.write_text("测试通话内容", encoding="utf-8")
        self.fake_root = self.root / "fake_modules"
        self.fake_root.mkdir()
        self.record_path = self.root / "prompt.json"
        self._write_fake_openai()

    def tearDown(self):
        self.tmp.cleanup()

    def _write_fake_openai(self):
        (self.fake_root / "openai.py").write_text(
            textwrap.dedent(
                """
                import json
                import os
                from types import SimpleNamespace


                class OpenAI:
                    def __init__(self, api_key=None, base_url=None):
                        self.chat = SimpleNamespace(
                            completions=SimpleNamespace(create=self._chat_create)
                        )
                        self.responses = SimpleNamespace(create=self._responses_create)

                    def _record(self, prompt):
                        record_path = os.environ["OPENAI_FAKE_RECORD_PATH"]
                        with open(record_path, "w", encoding="utf-8") as handle:
                            json.dump({"prompt": prompt}, handle, ensure_ascii=False)

                    def _chat_create(self, *, model, messages, temperature, max_tokens):
                        self._record(messages[0]["content"])
                        if os.environ.get("FAKE_OPENAI_FAIL") == "1":
                            raise RuntimeError("fake provider failure")
                        if os.environ.get("FAKE_OPENAI_EMPTY") == "1":
                            return SimpleNamespace(
                                choices=[SimpleNamespace(message=SimpleNamespace(content=""))]
                            )
                        message = SimpleNamespace(content="这是 fake 摘要")
                        choice = SimpleNamespace(message=message)
                        return SimpleNamespace(choices=[choice])

                    def _responses_create(self, *, model, input, temperature, max_output_tokens):
                        self._record(input)
                        if os.environ.get("FAKE_OPENAI_FAIL") == "1":
                            raise RuntimeError("fake provider failure")
                        if os.environ.get("FAKE_OPENAI_EMPTY") == "1":
                            return SimpleNamespace(output_text="")
                        return SimpleNamespace(output_text="这是 fake 摘要")
                """
            ),
            encoding="utf-8",
        )

    def run_script(self, input_path=None, *extra_args, env=None):
        environment = os.environ.copy()
        environment["OPENAI_API_KEY"] = "fake"
        environment["OPENAI_FAKE_RECORD_PATH"] = str(self.record_path)
        environment["PYTHONPATH"] = (
            f"{self.fake_root}{os.pathsep}{environment.get('PYTHONPATH', '')}"
        )
        if env:
            environment.update(env)

        return subprocess.run(
            [
                sys.executable,
                str(self.script_path),
                str(input_path or self.input_path),
                "test-model",
                *[str(arg) for arg in extra_args],
            ],
            capture_output=True,
            text=True,
            cwd=self.repo_root,
            env=environment,
            timeout=10,
        )

    def recorded_prompt(self):
        return json.loads(self.record_path.read_text(encoding="utf-8"))["prompt"]

    def test_explicit_output_path_and_full_input(self):
        marker = "END-OF-CONTENT"
        input_path = self.root / "combined.md"
        input_path.write_text("A" * 9000 + marker, encoding="utf-8")
        output_path = self.root / "versions" / "v1.md"

        result = self.run_script(
            input_path,
            "--output-path",
            output_path,
            "--document-title",
            "关系进展",
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output_path.exists())
        output = output_path.read_text(encoding="utf-8")
        self.assertIn("# 关系进展", output)
        self.assertIn(marker, self.recorded_prompt())

    def test_api_key_is_not_printed(self):
        secret = "secret-value-that-must-not-appear"

        result = self.run_script(env={"OPENAI_API_KEY": secret})

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(secret, result.stdout)
        self.assertNotIn(secret, result.stderr)

    def test_default_output_path_still_works(self):
        output_path = self.input_path.with_name("meeting_摘要.md")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output_path.exists())
        self.assertIn("# 摘要", output_path.read_text(encoding="utf-8"))

    def test_failure_does_not_leave_final_output(self):
        output_path = self.root / "versions" / "failed.md"

        result = self.run_script(
            self.input_path,
            "--output-path",
            output_path,
            env={"FAKE_OPENAI_FAIL": "1"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LLM 调用失败", result.stdout + result.stderr)
        self.assertIn("测试通话内容", self.recorded_prompt())
        self.assertFalse(output_path.exists())
        self.assertEqual(list(output_path.parent.glob("failed.md.*.tmp")), [])

    def test_invalid_output_directory_fails_before_provider_call(self):
        output_path = self.root / "versions" / "invalid.md"
        output_path.mkdir(parents=True)

        result = self.run_script(
            self.input_path,
            "--output-path",
            output_path,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("摘要保存失败", result.stdout + result.stderr)
        self.assertTrue(output_path.is_dir())
        self.assertFalse(self.record_path.exists())
        temp_files = list(output_path.parent.glob(f"{output_path.name}.*.tmp"))
        self.assertEqual(temp_files, [])

    def test_empty_summary_keeps_readable_error_message(self):
        output_path = self.root / "empty.md"

        result = self.run_script(
            self.input_path,
            "--output-path",
            output_path,
            env={"FAKE_OPENAI_EMPTY": "1"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("模型返回为空，未生成摘要内容", result.stdout + result.stderr)
        self.assertFalse(output_path.exists())


if __name__ == "__main__":
    unittest.main()
