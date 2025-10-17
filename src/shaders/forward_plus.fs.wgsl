// TODO-2: implement the Forward+ fragment shader

// See naive.fs.wgsl for basic fragment shader setup; this shader should use light clusters instead of looping over all lights

// ------------------------------------
// Shading process:
// ------------------------------------
// Determine which cluster contains the current fragment.
// Retrieve the number of lights that affect the current fragment from the cluster’s data.
// Initialize a variable to accumulate the total light contribution for the fragment.
// For each light in the cluster:
//     Access the light's properties using its index.
//     Calculate the contribution of the light based on its position, the fragment’s position, and the surface normal.
//     Add the calculated contribution to the total light accumulation.
// Multiply the fragment’s diffuse color by the accumulated light contribution.
// Return the final color, ensuring that the alpha component is set appropriately (typically to 1).

@group(${bindGroup_scene}) @binding(0) var<uniform> camera: CameraUniforms;
@group(${bindGroup_scene}) @binding(1) var<storage, read> lightSet: LightSet;
@group(${bindGroup_scene}) @binding(2) var<storage, read_write> clusterSet: ClusterSet;
@group(${bindGroup_scene}) @binding(3) var<uniform> screenTile: vec4f; // (screenW, screenH, tileW, tileH)

@group(${bindGroup_material}) @binding(0) var diffuseTex: texture_2d<f32>;
@group(${bindGroup_material}) @binding(1) var diffuseTexSampler: sampler;

struct FragmentInput
{
    @builtin(position) fragCoord: vec4f,
    @location(0) pos: vec3f,
    @location(1) nor: vec3f,
    @location(2) uv: vec2f
}

fn clusterIndex(clusterX: u32, clusterY: u32, clusterZ: u32) -> u32 {
    let gridSizeX = clusterSet.numClustersX;
    let gridSizeY = clusterSet.numClustersY;
    return (clusterZ * gridSizeY + clusterY) * gridSizeX + clusterX; // z-major order for cache coherency
}

fn z_to_slice(viewSpaceDepth: f32) -> u32 {
    let nearPlane = camera.nearFar.x;
    let farPlane = camera.nearFar.y;
    let totalDepthSlices = f32(clusterSet.numClustersZ);
    let normalizedDepth = clamp((log(viewSpaceDepth / nearPlane) / log(farPlane / nearPlane)), 0.0, 0.99999);
    return u32(floor(normalizedDepth * totalDepthSlices));
}

@fragment
fn main(in: FragmentInput) -> @location(0) vec4f
{
    let diffuseColor = textureSample(diffuseTex, diffuseTexSampler, in.uv);
    if (diffuseColor.a < 0.5f) {
        discard;
    }

    // Derive cluster coordinates
    let screenWidth = screenTile.x;
    let screenHeight = screenTile.y;
    let tileWidth = screenTile.z;
    let tileHeight = screenTile.w;

    let pixelX = in.fragCoord.x;
    let pixelY = in.fragCoord.y;

    let clusterX = u32(clamp(floor(pixelX / tileWidth), 0.0, f32(clusterSet.numClustersX - 1u)));
    let clusterY = u32(clamp(floor(pixelY / tileHeight), 0.0, f32(clusterSet.numClustersY - 1u)));

    // Calculate view-space depth for z-slice determination
    let fragViewSpace = (camera.viewMat * vec4f(in.pos, 1.0)).xyz;
    let viewSpaceDepth = max(-fragViewSpace.z, camera.nearFar.x);
    let clusterZ = z_to_slice(viewSpaceDepth);

    let currentClusterIndex = clusterIndex(clusterX, clusterY, clusterZ);
    let clusterLightCount = clusterSet.clusters[currentClusterIndex].numLights;
    let maxLightsPerCluster = ${maxLightsPerCluster}u;

    var accumulatedLightColor = vec3f(0.0, 0.0, 0.0);
    for (var lightIndex = 0u; lightIndex < min(clusterLightCount, maxLightsPerCluster); lightIndex++) {
        let lightId = clusterSet.clusters[currentClusterIndex].lightIndices[lightIndex];
        let currentLight = lightSet.lights[lightId];
        accumulatedLightColor += calculateLightContrib(currentLight, in.pos, normalize(in.nor));
    }

    var finalFragmentColor = diffuseColor.rgb * accumulatedLightColor;
    return vec4(finalFragmentColor, 1);
}
