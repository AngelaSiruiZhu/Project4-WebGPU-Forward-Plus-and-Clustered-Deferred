import { vec3 } from "wgpu-matrix";
import { device, canvas } from "../renderer";

import * as shaders from '../shaders/shaders';
import { Camera } from "./camera";

// h in [0, 1]
function hueToRgb(h: number) {
    let f = (n: number, k = (n + h * 6) % 6) => 1 - Math.max(Math.min(k, 4 - k, 1), 0);
    return vec3.lerp(vec3.create(1, 1, 1), vec3.create(f(5), f(3), f(1)), 0.8);
}

export class Lights {
    private camera: Camera;

    numLights = 5000;
    static readonly maxNumLights = 5000;
    static readonly numFloatsPerLight = 8; // vec3f is aligned at 16 byte boundaries

    static readonly lightIntensity = 0.1;

    lightsArray = new Float32Array(Lights.maxNumLights * Lights.numFloatsPerLight);
    lightSetStorageBuffer: GPUBuffer;

    timeUniformBuffer: GPUBuffer;

    moveLightsComputeBindGroupLayout: GPUBindGroupLayout;
    moveLightsComputeBindGroup: GPUBindGroup;
    moveLightsComputePipeline: GPUComputePipeline;

    // TODO-2: add layouts, pipelines, textures, etc. needed for light clustering here
    clusteringComputeBindGroupLayout: GPUBindGroupLayout;
    clusteringComputeBindGroup: GPUBindGroup;
    clusteringClearPipeline: GPUComputePipeline;
    clusteringAssignPipeline: GPUComputePipeline;

    clusterSetStorageBuffer: GPUBuffer;
        
    screenTileBuffer = new Float32Array(4); // screenW, screenH, tileW, tileH
    screenTileUniformBuffer: GPUBuffer;

    numClustersX: number;
    numClustersY: number;
    numClustersZ: number;
    maxLightsPerCluster: number;
    tileW: number;
    tileH: number;

    constructor(camera: Camera) {
        this.camera = camera;

        this.lightSetStorageBuffer = device.createBuffer({
            label: "lights",
            size: 16 + this.lightsArray.byteLength, // 16 for numLights + padding
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
        });
        this.populateLightsBuffer();
        this.updateLightSetUniformNumLights();

        this.timeUniformBuffer = device.createBuffer({
            label: "time uniform",
            size: 4,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
        });

        this.moveLightsComputeBindGroupLayout = device.createBindGroupLayout({
            label: "move lights compute bind group layout",
            entries: [
                { // lightSet
                    binding: 0,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: "storage" }
                },
                { // time
                    binding: 1,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: "uniform" }
                }
            ]
        });

        this.moveLightsComputeBindGroup = device.createBindGroup({
            label: "move lights compute bind group",
            layout: this.moveLightsComputeBindGroupLayout,
            entries: [
                {
                    binding: 0,
                    resource: { buffer: this.lightSetStorageBuffer }
                },
                {
                    binding: 1,
                    resource: { buffer: this.timeUniformBuffer }
                }
            ]
        });

        this.moveLightsComputePipeline = device.createComputePipeline({
            label: "move lights compute pipeline",
            layout: device.createPipelineLayout({
                label: "move lights compute pipeline layout",
                bindGroupLayouts: [ this.moveLightsComputeBindGroupLayout ]
            }),
            compute: {
                module: device.createShaderModule({
                    label: "move lights compute shader",
                    code: shaders.moveLightsComputeSrc
                }),
                entryPoint: "main"
            }
        });

        // TODO-2: initialize layouts, pipelines, textures, etc. needed for light clustering here
        this.tileW = shaders.constants.clusterTileSizeX;
        this.tileH = shaders.constants.clusterTileSizeY;
        this.numClustersZ = shaders.constants.clusterZSlices;
        this.numClustersX = Math.ceil(canvas.width / this.tileW);
        this.numClustersY = Math.ceil(canvas.height / this.tileH);
        this.maxLightsPerCluster = shaders.constants.maxLightsPerCluster;

        const numClusters = this.numClustersX * this.numClustersY * this.numClustersZ;
        const clusterBufferSize = 16 + (numClusters * (1 + this.maxLightsPerCluster) * 4);

        this.screenTileBuffer[0] = canvas.width;
        this.screenTileBuffer[1] = canvas.height;
        this.screenTileBuffer[2] = this.tileW;
        this.screenTileBuffer[3] = this.tileH;
        
        this.screenTileUniformBuffer = device.createBuffer({
            label: "screen tile uniforms",
            size: this.screenTileBuffer.byteLength,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
        });
        device.queue.writeBuffer(this.screenTileUniformBuffer, 0, this.screenTileBuffer);

        this.clusterSetStorageBuffer = device.createBuffer({
            label: "cluster set",
            size: clusterBufferSize,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
        });

        const header = new Uint32Array([this.numClustersX, this.numClustersY, this.numClustersZ, 0]);
        device.queue.writeBuffer(this.clusterSetStorageBuffer, 0, header);

        this.clusteringComputeBindGroupLayout = device.createBindGroupLayout({
            label: "clustering compute bind group layout",
            entries: [
                { // camera
                    binding: 0,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: "uniform" }
                },
                { // lightSet
                    binding: 1,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: "read-only-storage" }
                },
                { // cluster set
                    binding: 2,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: "storage" }
                },
                { // screen tile uniforms
                    binding: 3,
                    visibility: GPUShaderStage.COMPUTE,
                    buffer: { type: "uniform" }
                }
            ]
        });

        this.clusteringComputeBindGroup = device.createBindGroup({
            label: "clustering compute bind group",
            layout: this.clusteringComputeBindGroupLayout,
            entries: [
                { binding: 0, resource: { buffer: this.camera.uniformsBuffer } },
                { binding: 1, resource: { buffer: this.lightSetStorageBuffer } },
                { binding: 2, resource: { buffer: this.clusterSetStorageBuffer } },
                { binding: 3, resource: { buffer: this.screenTileUniformBuffer } }
            ]
        });

        const clusteringModule = device.createShaderModule({
            label: "clustering compute shader",
            code: shaders.clusteringComputeSrc
        });

        this.clusteringClearPipeline = device.createComputePipeline({
            label: "clustering clear pipeline",
            layout: device.createPipelineLayout({
                label: "clustering clear pipeline layout",
                bindGroupLayouts: [ this.clusteringComputeBindGroupLayout ]
            }),
            compute: {
                module: clusteringModule,
                entryPoint: "clear"
            }
        });

        this.clusteringAssignPipeline = device.createComputePipeline({
            label: "clustering assign pipeline",
            layout: device.createPipelineLayout({
                label: "clustering assign pipeline layout",
                bindGroupLayouts: [ this.clusteringComputeBindGroupLayout ]
            }),
            compute: {
                module: clusteringModule,
                entryPoint: "assign"
            }
        });
    }

    private populateLightsBuffer() {
        for (let lightIdx = 0; lightIdx < Lights.maxNumLights; ++lightIdx) {
            // light pos is set by compute shader so no need to set it here
            const lightColor = vec3.scale(hueToRgb(Math.random()), Lights.lightIntensity);
            this.lightsArray.set(lightColor, (lightIdx * Lights.numFloatsPerLight) + 4);
        }

        device.queue.writeBuffer(this.lightSetStorageBuffer, 16, this.lightsArray);
    }

    updateLightSetUniformNumLights() {
        device.queue.writeBuffer(this.lightSetStorageBuffer, 0, new Uint32Array([this.numLights]));
    }

    doLightClustering(encoder: GPUCommandEncoder) {
        // TODO-2: run the light clustering compute pass(es) here
        // implementing clustering here allows for reusing the code in both Forward+ and Clustered Deferred
        const pass = encoder.beginComputePass({ label: "light clustering compute"});
        pass.setBindGroup(0, this.clusteringComputeBindGroup);

        pass.setPipeline(this.clusteringClearPipeline);
        const numClusters = this.numClustersX * this.numClustersY * this.numClustersZ;
        const wgSize = shaders.constants.moveLightsWorkgroupSize;
        pass.dispatchWorkgroups(Math.ceil(numClusters / wgSize));

        pass.setPipeline(this.clusteringAssignPipeline);
        pass.dispatchWorkgroups(Math.ceil(numClusters / wgSize));

        pass.end();
    }

    // CHECKITOUT: this is where the light movement compute shader is dispatched from the host
    onFrame(time: number) {
        device.queue.writeBuffer(this.timeUniformBuffer, 0, new Float32Array([time]));

        // not using same encoder as render pass so this doesn't interfere with measuring actual rendering performance
        const encoder = device.createCommandEncoder();

        const computePass = encoder.beginComputePass();
        computePass.setPipeline(this.moveLightsComputePipeline);

        computePass.setBindGroup(0, this.moveLightsComputeBindGroup);

        const workgroupCount = Math.ceil(this.numLights / shaders.constants.moveLightsWorkgroupSize);
        computePass.dispatchWorkgroups(workgroupCount);

        computePass.end();

        device.queue.submit([encoder.finish()]);
    }
}
