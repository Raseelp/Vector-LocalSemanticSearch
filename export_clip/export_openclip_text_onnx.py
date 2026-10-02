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

# See export_openclip_vision_onnx.py's comment on this - nn.MultiheadAttention's
# eval-mode fast path bypasses the monkeypatch above with a fused op the ONNX
# exporter doesn't support, so it needs to be disabled here too.
torch.backends.mha.set_fastpath_enabled(False)

def main():
    print("Loading OpenCLIP ViT-B/32...")

    torch.backends.mkldnn.enabled = False
    torch.backends.mkl.enabled = False

    model, _, _ = open_clip.create_model_and_transforms(
        model_name="ViT-B-32",
        pretrained="openai"
    )

    model.eval()

    print("Creating wrapper...")

    class FullModelWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.model = clip_model

        def forward(self, text: torch.Tensor) -> torch.Tensor:
            x = self.model.encode_text(text, normalize=True)
            return x

    wrapper = FullModelWrapper(model)
    wrapper.eval()

    # Create example input
    example_input = torch.zeros((1, 77), dtype=torch.long)
    example_input[0, 0] = 49406  # Start token
    example_input[0, 1] = 723    # Example token
    example_input[0, 2] = 49407  # EOS token

    print("Exporting to ONNX...")
    output_path = "clip_text.onnx"

    # Batch is always 1 on the Android side today (one query at a time),
    # but exporting with a dynamic batch axis anyway costs nothing and
    # keeps this model consistent with the vision export.
    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            example_input,
            output_path,
            input_names=["input_ids"],
            output_names=["text_embeds"],
            dynamic_axes={
                "input_ids": {0: "batch"},
                "text_embeds": {0: "batch"},
            },
            opset_version=17,
            do_constant_folding=True,
        )

    print(f"\nExport complete: {output_path}")

if __name__ == "__main__":
    main()
