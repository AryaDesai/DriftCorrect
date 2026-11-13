import subprocess
import unittest
from unittest.mock import patch

import install_windows_environment as installer


class InstallerTests(unittest.TestCase):
    def test_driver_versions(self):
        for output, expected in [
            ("CUDA Version: 13.0", ["cuda13", "cuda12"]),
            ("CUDA Version: 12.8", ["cuda12"]),
            ("CUDA Version: 11.8", []),
            ("CUDA Version: N/A", []),
        ]:
            with self.subTest(output=output):
                self.assertEqual(installer.cuda_choices(output), expected)

    @patch.object(installer.shutil, "which", return_value="nvidia-smi")
    @patch.object(installer.subprocess, "run", side_effect=subprocess.TimeoutExpired("nvidia-smi", 20))
    def test_unresponsive_driver(self, run, which):
        self.assertEqual(installer.detect_cuda(), [])

    def run_setup(self, choices, codes):
        with patch.object(installer, "detect_cuda", return_value=choices), \
             patch.object(installer.subprocess, "run") as run:
            run.side_effect = [subprocess.CompletedProcess([], code) for code in codes]
            result = installer.main()
            return result, [call.args[0] for call in run.call_args_list]

    def test_successful_cuda13(self):
        result, calls = self.run_setup(["cuda13", "cuda12"], [0, 0])
        self.assertEqual(result, 0)
        self.assertEqual(calls[0][-2:], ["--extra", "cuda13"])
        self.assertEqual(len(calls), 2)

    def test_failed_kernel_falls_back_to_cuda12(self):
        result, calls = self.run_setup(["cuda13", "cuda12"], [0, 1, 0, 0])
        self.assertEqual(result, 0)
        self.assertEqual(calls[2][-2:], ["--extra", "cuda12"])

    def test_failed_gpu_install_falls_back_to_exact_cpu_sync(self):
        result, calls = self.run_setup(["cuda12"], [1, 0])
        self.assertEqual(result, 0)
        self.assertNotIn("--extra", calls[-1])
        self.assertNotIn("--inexact", calls[-1])
        self.assertIn("--locked", calls[-1])

    def test_cpu_install_failure_is_reported(self):
        result, calls = self.run_setup([], [1])
        self.assertEqual(result, 1)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
