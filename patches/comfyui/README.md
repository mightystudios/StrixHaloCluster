# ComfyUI patches

These patches are applied only by `setup-comfyui.sh` to its pinned local
ComfyUI checkout. They are stored below `patches/comfyui/` so
`setup-qwen3d8.sh`, which applies only `patches/*.patch` to `llama.cpp`,
cannot consume them.

## `comfyui-b0b7435-hunyuan3d-rocm-sdpa.patch`

Targets ComfyUI `v0.39.0`, commit
`b0b743566f65daafc423b4fea8a2fbda94b3384a`.

The native Hunyuan3D VAE uses PyTorch scaled dot-product attention directly
for its transformer and cross-attention decoder. On the tested Radeon 8060S
(`gfx1151`) stack with PyTorch `2.11.0+rocm10.0.0`, the default, AOTriton
Flash, and Efficient backends fail with `hipErrorInvalidValue`; Math SDPA
passes the exact float16 `[1,16,4096,64]` self-attention shape, the decoder's
`[1,16,8000,64]`-by-`[1,16,4096,64]` cross-attention shape, and the full VAE
decode.

The patch routes both direct Hunyuan3D VAE calls through Math SDPA only when
`COMFY_HY3D_FORCE_MATH_SDPA=1` is present in the ComfyUI process. The
installer runs each backend probe in a fresh process and sets that environment
variable automatically when default SDPA fails and Math succeeds. Other
ComfyUI attention paths, other processes, system ROCm, and the Qwen
`llama.cpp` services are unaffected.

Do not catch a failed fused launch and retry Math in the same process. A HIP
kernel error can remain pending and surface in a later operation. Select Math
before the first Hunyuan3D SDPA call, as this patch does.

When updating `COMFYUI_COMMIT`, verify the patch with:

```bash
git -C /path/to/ComfyUI apply --check \
  /path/to/patches/comfyui/comfyui-b0b7435-hunyuan3d-rocm-sdpa.patch
```

Refresh the patch against the new pinned revision if that check fails.
