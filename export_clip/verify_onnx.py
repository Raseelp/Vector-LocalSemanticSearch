import numpy as np
import torch
import torch.nn.functional as F
import onnxruntime as ort
import open_clip


def mobile_compatible_sdpa(query, key, value, attn_mask=None, dropout_p=0.0, is_causal=False):
    scale = query.size(-1) ** -0.5
    attn = torch.matmul(query, key.transpose(-2, -1)) * scale
    if attn_mask is not None:
        attn = attn + attn_mask
    attn = F.softmax(attn, dim=-1)
    if dropout_p > 0.0:
        attn = F.dropout(attn, p=dropout_p)
    return torch.matmul(attn, value)


F.scaled_dot_product_attention = mobile_compatible_sdpa


def cosine(a, b):
    a = a.reshape(-1)
    b = b.reshape(-1)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def max_abs_diff(a, b):
    return float(np.max(np.abs(a - b)))


def main():
    torch.manual_seed(0)
    torch.backends.mkldnn.enabled = False
    torch.backends.mkl.enabled = False

    print("Loading OpenCLIP ViT-B/32...")
    model, _, _ = open_clip.create_model_and_transforms(
        model_name="ViT-B-32", pretrained="openai"
    )
    model.eval()
    vision_model = model.visual

    class VisionWrapper(torch.nn.Module):
        def __init__(self, vision_encoder):
            super().__init__()
            self.vision = vision_encoder

        def forward(self, x):
            return F.normalize(self.vision(x), p=2, dim=-1)

    class TextWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.model = clip_model

        def forward(self, text):
            return self.model.encode_text(text, normalize=True)

    vision_wrapper = VisionWrapper(vision_model).eval()
    text_wrapper = TextWrapper(model).eval()

    # ---------------- Vision ----------------
    print("\n" + "=" * 60)
    print("VISION MODEL")
    print("=" * 60)

    vision_session = ort.InferenceSession("clip_vision.onnx", providers=["CPUExecutionProvider"])

    single = torch.randn(1, 3, 224, 224)
    batch6 = torch.randn(6, 3, 224, 224)

    with torch.no_grad():
        torch.backends.mha.set_fastpath_enabled(False)
        pt_slowpath_single = vision_wrapper(single).numpy()
        pt_slowpath_batch6 = vision_wrapper(batch6).numpy()

        torch.backends.mha.set_fastpath_enabled(True)
        pt_fastpath_single = vision_wrapper(single).numpy()

    onnx_single = vision_session.run(None, {"pixel_values": single.numpy()})[0]
    onnx_batch6 = vision_session.run(None, {"pixel_values": batch6.numpy()})[0]

    print(f"Output shape - single: {onnx_single.shape}, batch6: {onnx_batch6.shape}")

    print("\n[Export fidelity] PyTorch (slow path, = what was traced) vs ONNX, batch=1:")
    print(f"  cosine similarity : {cosine(pt_slowpath_single, onnx_single):.8f}")
    print(f"  max abs diff      : {max_abs_diff(pt_slowpath_single, onnx_single):.8e}")

    print("\n[Export fidelity] PyTorch (slow path) vs ONNX, batch=6 (row 0):")
    print(f"  cosine similarity : {cosine(pt_slowpath_batch6[0], onnx_batch6[0]):.8f}")
    print(f"  max abs diff      : {max_abs_diff(pt_slowpath_batch6[0], onnx_batch6[0]):.8e}")

    print("\n[Deployed-model compatibility] PyTorch (fast path, = currently deployed clip_vision_ts.pt) vs ONNX, batch=1:")
    print(f"  cosine similarity : {cosine(pt_fastpath_single, onnx_single):.8f}")
    print(f"  max abs diff      : {max_abs_diff(pt_fastpath_single, onnx_single):.8e}")

    print("\n[Dynamic batch sanity] batch=6 row-by-row vs 6 independent batch=1 calls:")
    worst_cos = 1.0
    worst_diff = 0.0
    for i in range(6):
        single_i = batch6[i : i + 1].numpy()
        onnx_single_i = vision_session.run(None, {"pixel_values": single_i})[0]
        c = cosine(onnx_batch6[i], onnx_single_i)
        d = max_abs_diff(onnx_batch6[i], onnx_single_i)
        worst_cos = min(worst_cos, c)
        worst_diff = max(worst_diff, d)
    print(f"  worst cosine similarity across 6 items: {worst_cos:.8f}")
    print(f"  worst max abs diff across 6 items     : {worst_diff:.8e}")

    # ---------------- Text ----------------
    print("\n" + "=" * 60)
    print("TEXT MODEL")
    print("=" * 60)

    text_session = ort.InferenceSession("clip_text.onnx", providers=["CPUExecutionProvider"])

    tokenizer = open_clip.get_tokenizer("ViT-B-32")
    phrases_batch1 = tokenizer(["a photo of a dog"])
    phrases_batch3 = tokenizer(
        ["a photo of a dog", "sunset over the hills", "birthday cake with candles"]
    )

    with torch.no_grad():
        torch.backends.mha.set_fastpath_enabled(False)
        pt_text_slow_1 = text_wrapper(phrases_batch1).numpy()
        pt_text_slow_3 = text_wrapper(phrases_batch3).numpy()

        torch.backends.mha.set_fastpath_enabled(True)
        pt_text_fast_1 = text_wrapper(phrases_batch1).numpy()

    onnx_text_1 = text_session.run(None, {"input_ids": phrases_batch1.numpy().astype(np.int64)})[0]
    onnx_text_3 = text_session.run(None, {"input_ids": phrases_batch3.numpy().astype(np.int64)})[0]

    print(f"Output shape - batch1: {onnx_text_1.shape}, batch3: {onnx_text_3.shape}")

    print("\n[Export fidelity] PyTorch (slow path) vs ONNX, batch=1:")
    print(f"  cosine similarity : {cosine(pt_text_slow_1, onnx_text_1):.8f}")
    print(f"  max abs diff      : {max_abs_diff(pt_text_slow_1, onnx_text_1):.8e}")

    print("\n[Export fidelity] PyTorch (slow path) vs ONNX, batch=3 (row 0):")
    print(f"  cosine similarity : {cosine(pt_text_slow_3[0], onnx_text_3[0]):.8f}")
    print(f"  max abs diff      : {max_abs_diff(pt_text_slow_3[0], onnx_text_3[0]):.8e}")

    print("\n[Deployed-model compatibility] PyTorch (fast path, = currently deployed clip_text_ts.pt) vs ONNX, batch=1:")
    print(f"  cosine similarity : {cosine(pt_text_fast_1, onnx_text_1):.8f}")
    print(f"  max abs diff      : {max_abs_diff(pt_text_fast_1, onnx_text_1):.8e}")

    print("\n[Cross-check] text vs vision, same scale: text/vision embeddings should both be unit-norm:")
    print(f"  |text embed|  = {np.linalg.norm(onnx_text_1):.6f}")
    print(f"  |vision embed| = {np.linalg.norm(onnx_single):.6f}")

    print("\nDone.")


if __name__ == "__main__":
    main()
