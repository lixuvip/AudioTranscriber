import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts import voiceprint


class VoiceprintSegmentSelectionTests(unittest.TestCase):
    def test_select_segments_skips_short_empty_and_other_speakers(self):
        segments = [
            {"speakerKey": "0", "start": 0.0, "end": 0.8, "text": "too short"},
            {"speakerKey": "0", "start": 1.0, "end": 5.0, "text": "usable"},
            {"speakerKey": "1", "start": 6.0, "end": 10.0, "text": "wrong speaker"},
            {"speakerKey": "0", "start": 11.0, "end": 14.0, "text": "   "},
            {"speakerKey": "0", "start": 15.0, "end": 18.0, "text": "usable too"},
        ]

        selected = voiceprint.select_training_segments(
            segments,
            speaker_key="0",
            min_seconds=2.0,
            max_samples=8,
        )

        self.assertEqual([s["text"] for s in selected], ["usable", "usable too"])

    def test_build_profile_marks_embedding_missing_without_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = voiceprint.build_profile_payload(
                speaker_name="张三",
                speaker_key="0",
                source_audio="/tmp/input.m4a",
                sample_paths=[Path(tmp) / "sample-001.wav"],
                embedding=None,
                embedding_model_available=False,
            )

        self.assertEqual(profile["displayName"], "张三")
        self.assertEqual(profile["embeddingStatus"], "missing_model")
        self.assertEqual(profile["requiredModel"]["id"], "speechbrain/spkrec-ecapa-voxceleb")
        self.assertEqual(len(profile["samples"]), 1)

    def test_write_profile_uses_stable_person_folder_for_non_ascii_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            library_dir = Path(tmp)
            payload = voiceprint.build_profile_payload(
                speaker_name="张三",
                speaker_key="0",
                source_audio="/tmp/input.m4a",
                sample_paths=[],
                embedding=None,
                embedding_model_available=False,
            )

            profile_path = voiceprint.write_profile(library_dir, payload)

            self.assertTrue(profile_path.exists())
            saved = json.loads(profile_path.read_text(encoding="utf-8"))
            self.assertEqual(saved["displayName"], "张三")
            self.assertIn(saved["id"], profile_path.as_posix())
            self.assertTrue(saved["id"].startswith("speaker-"))

    def test_find_ffmpeg_checks_homebrew_paths_when_app_path_is_minimal(self):
        existing = ["/opt/homebrew/bin/ffmpeg"]

        with patch.dict(os.environ, {"PATH": "/usr/bin:/bin"}, clear=False), \
             patch.object(voiceprint.shutil, "which", return_value=None), \
             patch.object(voiceprint.Path, "exists", autospec=True, side_effect=lambda self: str(self) in existing):
            self.assertEqual(voiceprint.find_ffmpeg(), "/opt/homebrew/bin/ffmpeg")

    def test_dependency_report_lists_installable_dependency_items(self):
        with patch.object(voiceprint, "find_ffmpeg", return_value=None), \
             patch.object(voiceprint, "_model_cache_exists", return_value=False), \
             patch.object(voiceprint.importlib.util, "find_spec", return_value=None):
            report = voiceprint.dependency_report()

        dependencies = {item["id"]: item for item in report["dependencies"]}

        self.assertEqual(
            set(dependencies),
            {"ffmpeg", "speechbrain", "torch", "torchaudio", "huggingface_hub", voiceprint.ECAPA_MODEL_ID},
        )
        self.assertFalse(dependencies["ffmpeg"]["ready"])
        self.assertIn("brew install ffmpeg", dependencies["ffmpeg"]["installCommand"])
        self.assertIn("${python}", dependencies["speechbrain"]["installCommand"])
        self.assertIn("pip install -U huggingface_hub", dependencies[voiceprint.ECAPA_MODEL_ID]["installCommand"])
        self.assertIn("snapshot_download", dependencies[voiceprint.ECAPA_MODEL_ID]["installCommand"])
        self.assertIn("huggingface_hub", report["missing"])

    def test_manual_capture_appends_source_groups_for_same_person(self):
        with tempfile.TemporaryDirectory() as tmp:
            sample_dir = Path(tmp)
            direct_sample = sample_dir / "direct.wav"
            meeting_sample = sample_dir / "meeting.wav"
            direct_sample.write_bytes(b"direct")
            meeting_sample.write_bytes(b"meeting")

            direct_profile = voiceprint.build_manual_capture_payload(
                existing_profile=None,
                speaker_name="张三",
                source_audio="/tmp/direct.m4a",
                sample_path=direct_sample,
                source_type="direct",
                embedding_model_available=False,
            )
            merged_profile = voiceprint.build_manual_capture_payload(
                existing_profile=direct_profile,
                speaker_name="张三",
                source_audio="/tmp/meeting.m4a",
                sample_path=meeting_sample,
                source_type="meeting",
                embedding_model_available=False,
            )

        self.assertEqual(merged_profile["displayName"], "张三")
        self.assertEqual([sample["sourceType"] for sample in merged_profile["samples"]], ["direct", "meeting"])
        groups = {group["sourceType"]: group for group in merged_profile["sampleGroups"]}
        self.assertEqual(groups["direct"]["sampleCount"], 1)
        self.assertEqual(groups["meeting"]["sampleCount"], 1)
        self.assertGreater(groups["direct"]["matchWeight"], groups["meeting"]["matchWeight"])
        self.assertEqual(merged_profile["createdAt"], direct_profile["createdAt"])

    def test_match_speakers_to_profiles_uses_best_unique_profile(self):
        speaker_embeddings = {
            "0": [1.0, 0.0, 0.0],
            "1": [0.0, 1.0, 0.0],
        }
        profile_embeddings = [
            {"id": "alice", "displayName": "Alice", "embedding": [0.98, 0.02, 0.0]},
            {"id": "bob", "displayName": "Bob", "embedding": [0.05, 0.95, 0.0]},
        ]

        matches = voiceprint.match_speakers_to_profiles(
            speaker_embeddings,
            profile_embeddings,
            threshold=0.72,
        )

        self.assertEqual(matches["0"]["displayName"], "Alice")
        self.assertEqual(matches["1"]["displayName"], "Bob")

    def test_apply_matches_to_speaker_map_updates_role_names(self):
        payload = {
            "title": "demo",
            "roles": [
                {"key": "0", "placeholder": "角色A", "displayName": "角色A"},
                {"key": "1", "placeholder": "角色B", "displayName": "角色B"},
            ],
            "segments": [],
        }
        matches = {
            "0": {
                "speakerKey": "0",
                "profileId": "alice",
                "displayName": "Alice",
                "score": 0.87654,
            }
        }

        updated = voiceprint.apply_matches_to_speaker_map(payload, matches)

        self.assertEqual(updated["roles"][0]["displayName"], "Alice")
        self.assertEqual(updated["roles"][0]["voiceprintMatch"]["score"], 0.8765)
        self.assertEqual(updated["roles"][1]["displayName"], "角色B")
        self.assertEqual(updated["voiceprintMatches"][0]["profileId"], "alice")


if __name__ == "__main__":
    unittest.main()
