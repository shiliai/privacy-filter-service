import os
from unittest.mock import patch

import pytest

from privacy_filter_service.config import (
    OPF_CHECKPOINT_ENV,
    Settings,
    load_settings,
)

VALID_TOML = """\
[service]
host = "0.0.0.0"
port = 8765
device = "cuda"
output_mode = "typed"
decode_mode = "viterbi"
decode_backend = "upstream"
model_path = "/mnt/LLM/OpenAI/privacy_filter"
log_level = "INFO"

[hook]
base_url = "http://127.0.0.1:8765"
request_timeout_s = 5.0
max_file_bytes = 262144
max_inflight_warns_per_5min = 1
"""


class TestLoadSettings:
    def test_valid_config(self):
        s = load_settings(config_text=VALID_TOML)
        assert s.service.port == 8765
        assert s.service.host == "0.0.0.0"
        assert s.service.device == "cuda"
        assert s.service.output_mode == "typed"
        assert s.service.decode_mode == "viterbi"
        assert s.service.decode_backend == "upstream"
        assert s.service.model_path == "/mnt/LLM/OpenAI/privacy_filter"
        assert s.service.log_level == "INFO"
        assert s.hook.base_url == "http://127.0.0.1:8765"
        assert s.hook.request_timeout_s == 5.0
        assert s.hook.max_file_bytes == 262144
        assert s.hook.max_inflight_warns_per_5min == 1

    def test_env_override_port(self):
        with patch.dict(os.environ, {"PRIVACY_FILTER_LISTEN_PORT": "9999"}):
            s = load_settings(config_text=VALID_TOML)
        assert s.service.port == 9999

    def test_env_override_host(self):
        with patch.dict(os.environ, {"PRIVACY_FILTER_LISTEN_HOST": "192.168.1.1"}):
            s = load_settings(config_text=VALID_TOML)
        assert s.service.host == "192.168.1.1"

    def test_env_override_device(self):
        with patch.dict(
            os.environ,
            {
                "PRIVACY_FILTER_DEVICE": "cpu",
                "PRIVACY_FILTER_MAX_FILE_BYTES": "1024",
            },
        ):
            s = load_settings(config_text=VALID_TOML)
        assert s.service.device == "cpu"

    def test_env_override_decode_backend(self):
        with patch.dict(os.environ, {"PRIVACY_FILTER_DECODE_BACKEND": "jit_gpu"}):
            s = load_settings(config_text=VALID_TOML)
        assert s.service.decode_backend == "jit_gpu"

    def test_invalid_port_crashes(self):
        toml = VALID_TOML.replace("port = 8765", "port = 99999")
        with patch.dict(os.environ, {}, clear=False):
            with pytest.raises(SystemExit):
                load_settings(config_text=toml)

    def test_missing_model_path_crashes(self):
        toml = VALID_TOML.replace(
            'model_path = "/mnt/LLM/OpenAI/privacy_filter"', ""
        )
        env = {k: v for k, v in os.environ.items() if k != OPF_CHECKPOINT_ENV}
        with patch.dict(os.environ, env, clear=True):
            with pytest.raises(SystemExit):
                load_settings(config_text=toml)

    def test_opf_checkpoint_fallback(self):
        toml = VALID_TOML.replace(
            'model_path = "/mnt/LLM/OpenAI/privacy_filter"', ""
        )
        env = {k: v for k, v in os.environ.items() if k != OPF_CHECKPOINT_ENV}
        env[OPF_CHECKPOINT_ENV] = "/from/env/checkpoint"
        with patch.dict(os.environ, env, clear=True):
            s = load_settings(config_text=toml)
        assert s.service.model_path == "/from/env/checkpoint"

    def test_privacy_filter_model_path_overrides_opf_checkpoint(self):
        env = {k: v for k, v in os.environ.items() if k not in (OPF_CHECKPOINT_ENV, "PRIVACY_FILTER_MODEL_PATH")}
        env[OPF_CHECKPOINT_ENV] = "/from/opf"
        env["PRIVACY_FILTER_MODEL_PATH"] = "/from/priv"
        with patch.dict(os.environ, env, clear=True):
            s = load_settings(config_text=VALID_TOML)
        assert s.service.model_path == "/from/priv"

    def test_invalid_device_crashes(self):
        toml = VALID_TOML.replace('device = "cuda"', 'device = "tpu"')
        with pytest.raises(SystemExit):
            load_settings(config_text=toml)

    def test_jit_gpu_decode_backend_requires_cuda(self):
        toml = (
            VALID_TOML.replace('device = "cuda"', 'device = "cpu"')
            .replace('decode_backend = "upstream"', 'decode_backend = "jit_gpu"')
            .replace("max_file_bytes = 262144", "max_file_bytes = 1024")
        )
        with pytest.raises(SystemExit):
            load_settings(config_text=toml)

    def test_cpu_device_requires_small_max_file_bytes(self):
        toml = VALID_TOML.replace('device = "cuda"', 'device = "cpu"')
        with pytest.raises(SystemExit):
            load_settings(config_text=toml)

    def test_cpu_device_accepts_small_max_file_bytes(self):
        toml = VALID_TOML.replace('device = "cuda"', 'device = "cpu"').replace(
            "max_file_bytes = 262144", "max_file_bytes = 1024"
        )
        s = load_settings(config_text=toml)
        assert s.service.device == "cpu"
        assert s.hook.max_file_bytes == 1024

    def test_max_file_bytes_exceeds_limit_crashes(self):
        toml = VALID_TOML.replace("max_file_bytes = 262144", "max_file_bytes = 2097152")
        with pytest.raises(SystemExit):
            load_settings(config_text=toml)

    def test_hook_defaults_when_missing(self):
        toml = VALID_TOML.split("[hook]")[0]
        s = load_settings(config_text=toml)
        assert s.hook.base_url == "http://127.0.0.1:8765"
        assert s.hook.request_timeout_s == 5.0
        assert s.hook.max_file_bytes == 262144
        assert s.hook.max_inflight_warns_per_5min == 1

    def test_settings_model_validate_directly(self):
        data = {
            "service": {
                "host": "0.0.0.0",
                "port": 8765,
                "device": "cuda",
                "output_mode": "typed",
                "decode_mode": "viterbi",
                "decode_backend": "upstream",
                "model_path": "/some/path",
                "log_level": "DEBUG",
            },
            "hook": {
                "base_url": "http://localhost:9000",
                "request_timeout_s": 10,
                "max_file_bytes": 500000,
                "max_inflight_warns_per_5min": 3,
            },
        }
        s = Settings.model_validate(data)
        assert s.service.port == 8765
        assert s.hook.max_inflight_warns_per_5min == 3
