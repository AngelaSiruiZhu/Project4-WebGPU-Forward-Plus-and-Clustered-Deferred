// TODO-3: implement the Clustered Deferred G-buffer fragment shader

// This shader should only store G-buffer information and should not do any shading.
@group(${bindGroup_material}) @binding(0) var diffuseTex: texture_2d<f32>;
@group(${bindGroup_material}) @binding(1) var diffuseTexSampler: sampler;

struct GBufferOutput { //world space
    @location(0) position: vec4f, 
    @location(1) normal: vec4f, 
    @location(2) albedo: vec4f 
}

struct FragmentInput { //world space
    @builtin(position) fragCoord: vec4f,
    @location(0) position: vec3f, 
    @location(1) normal: vec3f,
    @location(2) uv: vec2f
}

@fragment
fn main(in: FragmentInput) -> GBufferOutput {
    let albedo = textureSample(diffuseTex, diffuseTexSampler, in.uv);
    if (albedo.a < 0.5) {
        discard;
    }

    var output: GBufferOutput;
    output.position = vec4f(in.position, 1.0);
    output.normal = vec4f(normalize(in.normal), 0.0);
    output.albedo = albedo;
    return output;
}