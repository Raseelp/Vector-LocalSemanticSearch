import torch
import torch.nn.functional as F
import open_clip

def mobile_compatible_sdpa(query, key, value, attn_mask=None, dropout_p=0.0, is_causal=False):
    scale = query.size(-1) ** -0.5
    attn = torch.matmul(query, key.transpose(-2, -1)) * scale

    if attn_mask is not None:
        attn = attn + attn_mask

    attn = F.softmax(attn, dim=-1)

    if dropout_p > 0.0:
        attn = F.dropout(attn, p=dropout_p)

    output = torch.matmul(attn, value)
    return output

F.scaled_dot_product_attention = mobile_compatible_sdpa

# nn.MultiheadAttention's eval-mode "fast path" calls a fused C++ kernel
# (aten::_native_multi_head_attention) directly, bypassing the Python-level
# F.scaled_dot_product_attention monkeypatch above entirely - harmless for
# TorchScript (which has a built-in op for it) but unsupported by the ONNX
# exporter. Forcing the slow path routes it back through ops ONNX knows
# about, same as the TorchScript export's own patch was meant to ensure.
torch.backends.mha.set_fastpath_enabled(False)

def main():
    print("Loading OpenCLIP ViT-B/32 (vision only)...")

    torch.backends.mkldnn.enabled = False
    torch.backends.mkl.enabled = False
    torch.set_num_threads(1)

    model, _, _ = open_clip.create_model_and_transforms(
        model_name="ViT-B-32",
        pretrained="openai"
    )

    vision_model = model.visual
    vision_model.eval()

    print("Creating wrapper that outputs normalized embeddings...")

    # Wrapper that includes normalization - identical to the TorchScript
    # export's VisionWrapper, so the ONNX model's math is byte-for-byte the
    # same, just exported through a different path.
    class VisionWrapper(torch.nn.Module):
        def __init__(self, vision_encoder):
            super().__init__()
            self.vision = vision_encoder

        def forward(self, x):
            features = self.vision(x)
            # L2 normalize
            normalized = F.normalize(features, p=2, dim=-1)
            return normalized

    wrapper = VisionWrapper(vision_model)
    wrapper.eval()

    print("Exporting to ONNX...")
    example_input = torch.randn(1, 3, 224, 224)

    output_path = "clip_vision.onnx"

    # dynamic_axes on the batch dimension is required, not optional: the
    # Android side calls this model with batch size 1 for a single photo,
    # with small fixed batches while scanning, and with however many frames
    # a single video produced (uncapped) in one forward() call. A static
    # batch-size-1 export would only work for the single-image case and
    # throw a shape-mismatch for every batched call.
    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            example_input,
            output_path,
            input_names=["pixel_values"],
            output_names=["image_embeds"],
            dynamic_axes={
                "pixel_values": {0: "batch"},
                "image_embeds": {0: "batch"},
            },
            opset_version=17,
            do_constant_folding=True,
        )

    print(f"\nExport complete: {output_path}")

    # Benchmark (single image, matches the TorchScript export's own check)
    print("\n=== Performance Benchmark (PyTorch eager, for reference) ===")
    with torch.no_grad():
        import time

        for _ in range(3):
            _ = wrapper(example_input)

        times = []
        for _ in range(20):
            start = time.perf_counter()
            _ = wrapper(example_input)
            elapsed = (time.perf_counter() - start) * 1000
            times.append(elapsed)

        avg_time = sum(times) / len(times)
        min_time = min(times)
        max_time = max(times)

        print(f"Average inference: {avg_time:.1f}ms")
        print(f"Min: {min_time:.1f}ms, Max: {max_time:.1f}ms")
        print(f"Throughput: {1000/avg_time:.1f} images/sec")

if __name__ == "__main__":
    main()
