// TODO-2: implement the light clustering compute shader

// ------------------------------------
// Calculating cluster bounds:
// ------------------------------------
// For each cluster (X, Y, Z):
//     - Calculate the screen-space bounds for this cluster in 2D (XY).
//     - Calculate the depth bounds for this cluster in Z (near and far planes).
//     - Convert these screen and depth bounds into view-space coordinates.
//     - Store the computed bounding box (AABB) for the cluster.

// ------------------------------------
// Assigning lights to clusters:
// ------------------------------------
// For each cluster:
//     - Initialize a counter for the number of lights in this cluster.

//     For each light:
//         - Check if the light intersects with the cluster’s bounding box (AABB).
//         - If it does, add the light to the cluster's light list.
//         - Stop adding lights if the maximum number of lights is reached.

//     - Store the number of lights assigned to this cluster.

@group(${bindGroup_scene}) @binding(0) var<uniform> camera: CameraUniforms;
@group(${bindGroup_scene}) @binding(1) var<storage, read> lightSet: LightSet;
@group(${bindGroup_scene}) @binding(2) var<storage, read_write> clusterSet: ClusterSet;
@group(${bindGroup_scene}) @binding(3) var<uniform> screenTile: vec4f; // (screenW, screenH, tileW, tileH)

fn clusterIndex(clusterX: u32, clusterY: u32, clusterZ: u32) -> u32 {
    let gridSizeX = clusterSet.numClustersX;
    let gridSizeY = clusterSet.numClustersY;
    return (clusterZ * gridSizeY + clusterY) * gridSizeX + clusterX; // z-major order
}

@compute @workgroup_size(${moveLightsWorkgroupSize})
fn clear(@builtin(global_invocation_id) gid: vec3u) {
    let clusterGridSizeX = clusterSet.numClustersX;
    let clusterGridSizeY = clusterSet.numClustersY;
    let clusterGridSizeZ = clusterSet.numClustersZ;
    let totalClusterCount = clusterGridSizeX * clusterGridSizeY * clusterGridSizeZ;

    let clusterIndex = gid.x;
    if (clusterIndex < totalClusterCount) {
        clusterSet.clusters[clusterIndex].numLights = 0u;
    }
}

fn projectToNdc(pView: vec3f) -> vec2f {
    let clip = camera.projMat * vec4f(pView, 1.0);
    return clip.xy / clip.w;
}

fn z_to_slice_idx(z: f32) -> u32 {
    let nearZ = camera.nearFar.x;
    let farZ = camera.nearFar.y;
    let dimZ = f32(clusterSet.numClustersZ);
    let l = clamp((log(z / nearZ) / log(farZ / nearZ)), 0.0, 0.99999);
    return u32(floor(l * dimZ));
}

@compute @workgroup_size(${moveLightsWorkgroupSize})
fn assign(@builtin(global_invocation_id) gid: vec3u) {

    let gridSizeX = clusterSet.numClustersX;
    let gridSizeY = clusterSet.numClustersY;
    let gridSizeZ = clusterSet.numClustersZ;
    let totalClusterCount = gridSizeX * gridSizeY * gridSizeZ;

    let globalClusterIndex = gid.x;
    if (globalClusterIndex >= totalClusterCount) { return; }

    // 1D -> 3D
    let clustersInXYPlane = gridSizeX * gridSizeY;
    let clusterZ = globalClusterIndex / clustersInXYPlane;
    let remainder = globalClusterIndex - clusterZ * clustersInXYPlane;
    let clusterY = remainder / gridSizeX;
    let clusterX = remainder - clusterY * gridSizeX;

    let currClusterIndex = globalClusterIndex;

    let screenW = screenTile.x;
    let screenH = screenTile.y;
    let tileW = screenTile.z;
    let tileH = screenTile.w;

    // pixel-space bounds for this tile
    let tileMinX = f32(clusterX) * tileW;
    let tileMaxX = min(f32(clusterX + 1u) * tileW, screenW);
    let tileMinY = f32(clusterY) * tileH;
    let tileMaxY = min(f32(clusterY + 1u) * tileH, screenH);

    // z-depth
    let nearPlane = camera.nearFar.x;
    let farPlane = camera.nearFar.y;
    let totalDepthSlices = f32(gridSizeZ);
    let sliceLowerBound = f32(clusterZ) / totalDepthSlices;
    let sliceUpperBound = f32(clusterZ + 1u) / totalDepthSlices;
    let clusterMinDepth = nearPlane * pow(farPlane / nearPlane, sliceLowerBound);
    let clusterMaxDepth = nearPlane * pow(farPlane / nearPlane, sliceUpperBound);

    let maxLightsPerCluster = ${maxLightsPerCluster}u;
    let lightSphereRadius = f32(${lightRadius});

    for (var lightIndex = 0u; lightIndex < lightSet.numLights; lightIndex++) {
        let currLight = lightSet.lights[lightIndex];


        let lightViewSpace4 = camera.viewMat * vec4f(currLight.pos, 1.0); // light position in view space
        let lightViewSpace = lightViewSpace4.xyz;
        let lightDepth = -lightViewSpace.z;

        let lightMinDepth = max(nearPlane, lightDepth - lightSphereRadius);
        let lightMaxDepth = min(farPlane, lightDepth + lightSphereRadius);
        if (lightMinDepth >= lightMaxDepth) { continue; }
        if (clusterMaxDepth <= lightMinDepth || clusterMinDepth >= lightMaxDepth) { continue; }

        let sphereLeftNDC = projectToNdc(vec3f(lightViewSpace.x - lightSphereRadius, lightViewSpace.y, lightViewSpace.z)).x;
        let sphereRightNDC = projectToNdc(vec3f(lightViewSpace.x + lightSphereRadius, lightViewSpace.y, lightViewSpace.z)).x;
        let sphereBottomNDC = projectToNdc(vec3f(lightViewSpace.x, lightViewSpace.y - lightSphereRadius, lightViewSpace.z)).y;
        let sphereTopNDC = projectToNdc(vec3f(lightViewSpace.x, lightViewSpace.y + lightSphereRadius, lightViewSpace.z)).y;

        var ndcBoundsMinX = min(sphereLeftNDC, sphereRightNDC);
        var ndcBoundsMaxX = max(sphereLeftNDC, sphereRightNDC);
        var ndcBoundsMinY = min(sphereBottomNDC, sphereTopNDC);
        var ndcBoundsMaxY = max(sphereBottomNDC, sphereTopNDC);

        // NDC bounds -> screen-space
        let lightScreenMinX = (ndcBoundsMinX * 0.5 + 0.5) * screenW;
        let lightScreenMaxX = (ndcBoundsMaxX * 0.5 + 0.5) * screenW;

        let lightScreenMinY = (1.0 - (ndcBoundsMaxY * 0.5 + 0.5)) * screenH;
        let lightScreenMaxY = (1.0 - (ndcBoundsMinY * 0.5 + 0.5)) * screenH;

        if (lightScreenMaxX <= tileMinX || lightScreenMinX >= tileMaxX) { continue; }
        if (lightScreenMaxY <= tileMinY || lightScreenMinY >= tileMaxY) { continue; }

        let currLightCount = clusterSet.clusters[currClusterIndex].numLights;
        if (currLightCount < maxLightsPerCluster) {
            clusterSet.clusters[currClusterIndex].lightIndices[currLightCount] = lightIndex;
            clusterSet.clusters[currClusterIndex].numLights = currLightCount + 1u;
        }
    }
}
