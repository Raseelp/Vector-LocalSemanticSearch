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
    
    # Wrapper that includes normalization
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

    print("Tracing vision encoder...")
    example_input = torch.randn(1, 3, 224, 224)

    with torch.no_grad():
        traced_model = torch.jit.trace(
            wrapper,
            example_input,
            check_trace=False
        )

    print("Freezing and optimizing...")
    traced_model = torch.jit.freeze(traced_model.eval())
    
    # Optimize for mobile with all optimizations enabled
    from torch.utils.mobile_optimizer import optimize_for_mobile
    optimized_model = optimize_for_mobile(
        traced_model,
        backend='CPU'
    )

    # Save in mobile format
    output_path = "clip_vision_ts.pt"
    optimized_model._save_for_lite_interpreter(output_path)

    print(f"\n✓ Export complete: {output_path}")
    
    # Benchmark
    print("\n=== Performance Benchmark ===")
    with torch.no_grad():
        import time
        
        # Warmup
        for _ in range(3):
            _ = optimized_model(example_input)
        
        # Measure
        times = []
        for _ in range(20):
            start = time.perf_counter()
            _ = optimized_model(example_input)
            elapsed = (time.perf_counter() - start) * 1000
            times.append(elapsed)
        
        avg_time = sum(times) / len(times)
        min_time = min(times)
        max_time = max(times)
        
        print(f"Average inference: {avg_time:.1f}ms")
        print(f"Min: {min_time:.1f}ms, Max: {max_time:.1f}ms")
        print(f"Throughput: {1000/avg_time:.1f} images/sec")
        
    # Verify output
    print("\n=== Verification ===")
    with torch.no_grad():
        original = F.normalize(vision_model(example_input), dim=-1)
        optimized = optimized_model(example_input)
        
        print(f"Original shape: {original.shape}")
        print(f"Optimized shape: {optimized.shape}")
        print(f"Max difference: {torch.max(torch.abs(original - optimized)).item():.6f}")
        print(f"Outputs match: {torch.allclose(original, optimized, atol=1e-4)}")

if __name__ == "__main__":
    main()