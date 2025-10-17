// TODO-3: implement the Clustered Deferred fullscreen fragment shader

// Similar to the Forward+ fragment shader, but with vertex information coming from the G-buffer instead.

@group(${bindGroup_scene}) @binding(0) var<uniform> camera: CameraUniforms;
@group(${bindGroup_scene}) @binding(1) var<storage, read> lightSet: LightSet;
@group(${bindGroup_scene}) @binding(2) var<storage, read_write> clusterSet: ClusterSet;
@group(${bindGroup_scene}) @binding(3) var<uniform> screenTile: vec4f;

@group(1) @binding(0) var positionTex: texture_2d<f32>;
@group(1) @binding(1) var normalTex: texture_2d<f32>;
@group(1) @binding(2) var albedoTex: texture_2d<f32>;
@group(1) @binding(3) var texSampler: sampler;

fn mapDepthToClusterLayer(viewSpaceDepth: f32) -> u32 {
    let nearPlane = camera.nearFar.x;
    let farPlane = camera.nearFar.y;
    let totalDepthSlices = f32(clusterSet.numClustersZ);
    let logDepth = clamp((log(viewSpaceDepth / nearPlane) / log(farPlane / nearPlane)), 0.0, 0.99999);
    return u32(floor(logDepth * totalDepthSlices));
}

fn clusterIndex(clusterX: u32, clusterY: u32, clusterZ: u32) -> u32 {
    let gridSizeX = clusterSet.numClustersX;
    let gridSizeY = clusterSet.numClustersY;
    return (clusterZ * gridSizeY + clusterY) * gridSizeX + clusterX;
}

struct FragmentInput {
    @builtin(position) fragCoord: vec4f,
    @location(0) uv: vec2f
}

@fragment
fn main(in: FragmentInput) -> @location(0) vec4f {
    let worldPos = textureSample(positionTex, texSampler, in.uv).xyz;
    let normal = textureSample(normalTex, texSampler, in.uv).xyz;
    let albedo = textureSample(albedoTex, texSampler, in.uv);

    if (albedo.a < 0.5) { //transparent pixels
        discard;
    }

    // cluster coordinates
    let screenW = screenTile.x;
    let screenH = screenTile.y;
    let tileW = screenTile.z;
    let tileH = screenTile.w;

    let pixelX = in.fragCoord.x;
    let pixelY = in.fragCoord.y;

    let clusterX = u32(clamp(floor(pixelX / tileW), 0.0, f32(clusterSet.numClustersX - 1u)));
    let clusterY = u32(clamp(floor(pixelY / tileH), 0.0, f32(clusterSet.numClustersY - 1u)));

    let viewPos = (camera.viewMat * vec4f(worldPos, 1.0)).xyz;
    let viewSpaceDepth = max(-viewPos.z, camera.nearFar.x);
    let clusterZ = mapDepthToClusterLayer(viewSpaceDepth);

    let currClusterIndex = clusterIndex(clusterX, clusterY, clusterZ);
    let clusterLightCount = clusterSet.clusters[currClusterIndex].numLights;
    let maxLightsPerCluster = ${maxLightsPerCluster}u;

    var totalLight = vec3f(0.0);
    for (var i = 0u; i < min(clusterLightCount, maxLightsPerCluster); i++) {
        let lightIndex = clusterSet.clusters[currClusterIndex].lightIndices[i];
        let light = lightSet.lights[lightIndex];
        totalLight += calculateLightContrib(light, worldPos, normalize(normal));
    }

    return vec4f(albedo.rgb * totalLight, 1.0);
}
