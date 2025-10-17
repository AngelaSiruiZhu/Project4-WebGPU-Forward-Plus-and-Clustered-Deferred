// TODO-3: implement the Clustered Deferred fullscreen vertex shader

// This shader should be very simple as it does not need all of the information passed by the the naive vertex shader.

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f
}

@vertex
fn main(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {

    var output: VertexOutput;
    
    let vertex_x = f32(i32(vertexIndex & 1u) * 4 - 1);
    let vertex_y = f32(i32(vertexIndex >> 1u) * 4 - 1);
    output.position = vec4f(vertex_x, vertex_y, 0.0, 1.0);

    output.uv = vec2f(
        vertex_x * 0.5 + 0.5,
        0.5 - vertex_y * 0.5
    );
    return output;
}
