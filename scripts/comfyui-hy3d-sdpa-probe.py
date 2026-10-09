#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


CASES = {
    "tiny_flash": {
        "backend": "FLASH_ATTENTION",
        "layout": "self",
        "query_sequence": 8,
        "key_sequence": 8,
        "heads": 1,
    },
    "hunyuan_flash": {
        "backend": "FLASH_ATTENTION",
        "layout": "self",
        "query_sequence": 4096,
        "key_sequence": 4096,
        "heads": 16,
    },
    "hunyuan_efficient": {
        "backend": "EFFICIENT_ATTENTION",
        "layout": "self",
        "query_sequence": 4096,
        "key_sequence": 4096,
        "heads": 16,
    },
    "hunyuan_math": {
        "backend": "MATH",
        "layout": "self",
        "query_sequence": 4096,
        "key_sequence": 4096,
        "heads": 16,
    },
    "hunyuan_cross_math": {
        "backend": "MATH",
        "layout": "cross",
        "query_sequence": 8000,
        "key_sequence": 4096,
        "heads": 16,
    },
    "hunyuan_default": {
        "backend": "DEFAULT",
        "layout": "self",
        "query_sequence": 4096,
        "key_sequence": 4096,
        "heads": 16,
    },
    "hunyuan_cross_default": {
        "backend": "DEFAULT",
        "layout": "cross",
        "query_sequence": 8000,
        "key_sequence": 4096,
        "heads": 16,
    },
}


def run_child(case_name: str) -> int:
    import torch
    import torch.nn.functional as functional
    from torch.nn.attention import SDPBackend, sdpa_kernel

    case = CASES[case_name]
    backend_name = case["backend"]
    layout = case["layout"]
    query_sequence = case["query_sequence"]
    key_sequence = case["key_sequence"]
    heads = case["heads"]
    head_dim = 64

    result: dict[str, Any] = {
        "case": case_name,
        "backend": backend_name,
        "torch": torch.__version__,
        "torch_git": torch.version.git_version,
        "torch_hip": torch.version.hip,
    }

    try:
        if not torch.cuda.is_available():
            raise RuntimeError("ROCm GPU is not available to PyTorch")

        properties = torch.cuda.get_device_properties(0)
        result["device"] = properties.name
        result["gcn_arch"] = getattr(properties, "gcnArchName", None)
        result["flash_built"] = torch.backends.cuda.is_flash_attention_available()
        result["preferred_rocm_fa"] = str(
            torch.backends.cuda.preferred_rocm_fa_library()
        )

        torch.manual_seed(0)
        if layout == "self":
            qkv = torch.randn(
                (1, query_sequence, heads, 3 * head_dim),
                device="cuda",
                dtype=torch.float16,
            )
            query, key, value = qkv.split(head_dim, dim=-1)
        else:
            query = torch.randn(
                (1, query_sequence, heads, head_dim),
                device="cuda",
                dtype=torch.float16,
            )
            key_value = torch.randn(
                (1, key_sequence, heads, 2 * head_dim),
                device="cuda",
                dtype=torch.float16,
            )
            key, value = key_value.split(head_dim, dim=-1)
        query = functional.layer_norm(query, (head_dim,))
        key = functional.layer_norm(key, (head_dim,))
        query, key, value = [
            tensor.permute(0, 2, 1, 3)
            for tensor in (query, key, value)
        ]
        result["layout"] = layout
        result["query_shape"] = list(query.shape)
        result["key_shape"] = list(key.shape)
        result["value_shape"] = list(value.shape)
        result["query_stride"] = list(query.stride())
        result["key_stride"] = list(key.stride())
        result["value_stride"] = list(value.stride())

        with torch.inference_mode():
            if backend_name == "DEFAULT":
                output = functional.scaled_dot_product_attention(
                    query,
                    key,
                    value,
                )
            else:
                backend = getattr(SDPBackend, backend_name)
                with sdpa_kernel(backend):
                    output = functional.scaled_dot_product_attention(
                        query,
                        key,
                        value,
                    )
            torch.cuda.synchronize()

        result.update(
            {
                "passed": True,
                "finite": bool(output.isfinite().all().item()),
                "nonzero": int(output.count_nonzero().item()),
                "absmax": float(output.abs().max().item()),
                "output_shape": list(output.shape),
            }
        )
        if not result["finite"] or result["nonzero"] == 0:
            raise RuntimeError("SDPA output is non-finite or entirely zero")
    except Exception as error:
        result.update(
            {
                "passed": False,
                "error_type": type(error).__name__,
                "error": str(error).splitlines()[0],
            }
        )

    print(json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1


def run_isolated_case(case_name: str) -> dict[str, Any]:
    environment = os.environ.copy()
    environment["AMD_SERIALIZE_KERNEL"] = "1"
    try:
        process = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--child-case",
                case_name,
            ],
            capture_output=True,
            check=False,
            env=environment,
            text=True,
            timeout=300,
        )
    except subprocess.TimeoutExpired as error:
        return {
            "case": case_name,
            "passed": False,
            "error_type": type(error).__name__,
            "error": "probe exceeded its 300-second timeout",
        }

    output_lines = [
        line
        for line in process.stdout.splitlines()
        if line.strip()
    ]
    if not output_lines:
        return {
            "case": case_name,
            "passed": False,
            "error_type": "ProbeProcessError",
            "error": "probe did not produce JSON output",
            "returncode": process.returncode,
            "stderr": process.stderr[-2000:],
        }

    try:
        result = json.loads(output_lines[-1])
    except json.JSONDecodeError as error:
        return {
            "case": case_name,
            "passed": False,
            "error_type": type(error).__name__,
            "error": str(error),
            "returncode": process.returncode,
            "stdout": process.stdout[-2000:],
            "stderr": process.stderr[-2000:],
        }

    result["returncode"] = process.returncode
    if process.stderr:
        result["stderr"] = process.stderr[-2000:]
    if process.returncode != 0:
        result["passed"] = False
        result.setdefault("error_type", "ProbeProcessError")
        result.setdefault(
            "error",
            f"probe process exited with status {process.returncode}",
        )
    return result


def select_mode(
    requested_mode: str,
    results: dict[str, dict[str, Any]],
) -> str:
    default_passed = all(
        results[case_name].get("passed")
        for case_name in ("hunyuan_default", "hunyuan_cross_default")
    )
    math_passed = all(
        results[case_name].get("passed")
        for case_name in ("hunyuan_math", "hunyuan_cross_math")
    )

    if requested_mode == "default":
        if not default_passed:
            raise RuntimeError(
                "default HY 3D SDPA was requested but failed its probe"
            )
        return "default"

    if requested_mode == "math":
        if not math_passed:
            raise RuntimeError(
                "Math HY 3D SDPA was requested but failed its probe"
            )
        return "math"

    if default_passed:
        return "default"
    if math_passed:
        return "math"
    raise RuntimeError("both default and Math HY 3D SDPA probes failed")


def write_state(path: Path, selected_mode: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        text=True,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(selected_mode + "\n")
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Probe PyTorch SDPA backends using the native Hunyuan3D VAE "
            "float16 self-attention and cross-attention layouts."
        )
    )
    parser.add_argument(
        "--requested-mode",
        choices=("auto", "default", "math"),
        default="auto",
        help="Required backend policy; auto selects default or falls back to Math.",
    )
    parser.add_argument(
        "--state-file",
        type=Path,
        help="Write the selected mode atomically to this file.",
    )
    parser.add_argument(
        "--child-case",
        choices=tuple(CASES),
        help=argparse.SUPPRESS,
    )
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    if arguments.child_case:
        return run_child(arguments.child_case)

    results = {
        case_name: run_isolated_case(case_name)
        for case_name in CASES
    }
    for case_name, result in results.items():
        status = "PASS" if result.get("passed") else "FAIL"
        detail = result.get("error", "finite, nonzero output")
        print(f"HY 3D SDPA {case_name}: {status} - {detail}")

    try:
        selected_mode = select_mode(arguments.requested_mode, results)
    except RuntimeError as error:
        print(
            json.dumps(
                {
                    "requested_mode": arguments.requested_mode,
                    "selected_mode": None,
                    "error": str(error),
                    "results": results,
                },
                sort_keys=True,
            )
        )
        return 1

    if arguments.state_file:
        write_state(arguments.state_file, selected_mode)

    print(
        json.dumps(
            {
                "requested_mode": arguments.requested_mode,
                "selected_mode": selected_mode,
                "results": results,
            },
            sort_keys=True,
        )
    )
    print(f"Selected Hunyuan3D SDPA mode: {selected_mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
