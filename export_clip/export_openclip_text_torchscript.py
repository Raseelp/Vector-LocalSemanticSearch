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

    print("Tracing model...")
    
    with torch.no_grad():
        traced_model = torch.jit.trace(wrapper, example_input, check_trace=False, strict=False)

    traced_model = torch.jit.freeze(traced_model.eval())
    
    from torch.utils.mobile_optimizer import optimize_for_mobile
    optimized_model = optimize_for_mobile(traced_model)

    output_path = "clip_text_ts.pt"
    optimized_model._save_for_lite_interpreter(output_path)

    print(f"\n✓ Export complete: {output_path}")
    print("✓ Copy this file to app/src/main/assets/ in your Android project")

if __name__ == "__main__":
    main()