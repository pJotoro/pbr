package pbr

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:mem"
import vk "vendor:vulkan"
import "core:debug/trace"

MAX_FRAMES_IN_FLIGHT :: 2

Vulkan_Frame :: struct {
    command_buffer: vk.CommandBuffer,
    sem_image_available: vk.Semaphore,
    sem_render_finished: vk.Semaphore,
    fence_in_flight: vk.Fence,
}

Vulkan :: struct {
    arena: mem.Allocator,

    lib: dynlib.Library,

    instance: vk.Instance,
    instance_layer_properties: []vk.LayerProperties,
    instance_extension_properties: []vk.ExtensionProperties,

    physical_device: vk.PhysicalDevice,
    physical_device_properties: vk.PhysicalDeviceProperties2,
    physical_device_vulkan_11_properties: vk.PhysicalDeviceVulkan11Properties,
    physical_device_vulkan_12_properties: vk.PhysicalDeviceVulkan12Properties,
    physical_device_vulkan_13_properties: vk.PhysicalDeviceVulkan13Properties,
    physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
    physical_device_features: vk.PhysicalDeviceFeatures2,
    physical_device_vulkan_11_features: vk.PhysicalDeviceVulkan11Features,
    physical_device_vulkan_12_features: vk.PhysicalDeviceVulkan12Features,
    physical_device_vulkan_13_features: vk.PhysicalDeviceVulkan13Features,

    physical_device_extended_dynamic_state_3_properties: vk.PhysicalDeviceExtendedDynamicState3PropertiesEXT,
    physical_device_extended_dynamic_state_3_features: vk.PhysicalDeviceExtendedDynamicState3FeaturesEXT,

    physical_device_vertex_input_dynamic_state_features: vk.PhysicalDeviceVertexInputDynamicStateFeaturesEXT,
    
    surface: vk.SurfaceKHR,
    surface_capabilities: vk.SurfaceCapabilitiesKHR,
    surface_formats: []vk.SurfaceFormatKHR,

    device: vk.Device,
    device_extension_properties: []vk.ExtensionProperties,
    
    queue_family_properties: []vk.QueueFamilyProperties,
    queues: []vk.Queue,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,

    swapchain: vk.SwapchainKHR,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    swapchain_format: vk.SurfaceFormatKHR,
    swapchain_extent: vk.Extent2D,
    swapchain_frame_buffers: []vk.Framebuffer,

    frames: []Vulkan_Frame,
    current_frame: int,

    vert_shader_module: vk.ShaderModule,
    frag_shader_module: vk.ShaderModule,
    shader_stages: [2]vk.PipelineShaderStageCreateInfo,

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    command_pool: vk.CommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,

    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
    render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence,

    staged: bool,
    image_idx: u32,
}

VULKAN_DEBUG :: #config(VULKAN_DEBUG, ODIN_DEBUG)

when VULKAN_DEBUG {
    vulkan_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user_data: rawptr) -> b32
    {
        runtime.print_string(string(data.pMessage))
        runtime.print_byte('\n')
        return false
    }
}

vulkan_init :: proc(using vulkan: ^Vulkan) -> vk.Result {
    {
        did_load: bool
        if lib, did_load = dynlib.load_library(VULKAN_LIB_NAME); !did_load {
            return .ERROR_INCOMPATIBLE_DRIVER 
        }
    }
    {
        vkGetInstanceProcAddr := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
        vk.load_proc_addresses_global(vkGetInstanceProcAddr)
    }
    {
        if (vk.EnumerateInstanceVersion == nil) {
            return .ERROR_INCOMPATIBLE_DRIVER
        }
        api_version: u32
        vk.EnumerateInstanceVersion(&api_version) or_return
        if api_version < vk.API_VERSION_1_3 {
            return .ERROR_INCOMPATIBLE_DRIVER
        }
    }

    when VULKAN_DEBUG {
        instance_layers := [?]cstring {
            "VK_LAYER_KHRONOS_validation", 
            "VK_LAYER_LUNARG_monitor",
        }

        instance_extensions := [?]cstring {
            "VK_EXT_debug_utils", 
            "VK_EXT_layer_settings",

            "VK_KHR_surface",
            VK_KHR_platform_surface,
        }
    } else {
        instance_extensions := [?]cstring {
            "VK_KHR_surface",
            VK_KHR_platform_surface,
        }
    }
    when VULKAN_DEBUG {
        instance_layer_count: u32
        vk.EnumerateInstanceLayerProperties(&instance_layer_count, nil) or_return
        instance_layer_properties = make([]vk.LayerProperties, instance_layer_count, arena)
        vk.EnumerateInstanceLayerProperties(&instance_layer_count, raw_data(instance_layer_properties)) or_return

        for layer in instance_layers {
            found := false
            for &props in instance_layer_properties {
                if layer == cstring(raw_data(props.layerName[:])) {
                    found = true
                    break
                }
            }
            if !found {
                return .ERROR_LAYER_NOT_PRESENT
            }
        }
    }

    {
        instance_extension_count: u32
        vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil) or_return
        for instance_layer in instance_layers {
            count: u32
            vk.EnumerateInstanceExtensionProperties(instance_layer, &count, nil) or_return
            instance_extension_count += count

        }
        instance_extension_properties = make([]vk.ExtensionProperties, instance_extension_count, arena)
        
        cur_instance_extension_properties := instance_extension_properties
        {
            count := u32(len(cur_instance_extension_properties))
            vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(cur_instance_extension_properties)) or_return
            cur_instance_extension_properties = cur_instance_extension_properties[int(count):]
        }
        for instance_layer in instance_layers {
            count := u32(len(cur_instance_extension_properties))
            vk.EnumerateInstanceExtensionProperties(instance_layer, &count, raw_data(cur_instance_extension_properties)) or_return
            cur_instance_extension_properties = cur_instance_extension_properties[int(count):]
        }

        for extension in instance_extensions {
            found := false
            for &props in instance_extension_properties {
                if extension == cstring(raw_data(props.extensionName[:])) {
                    found = true
                    break
                }
            }
            if !found {
                return .ERROR_EXTENSION_NOT_PRESENT
            }
        }
    }
    {
        app_info := vk.ApplicationInfo {
            sType = .APPLICATION_INFO,
            pApplicationName = "pbr",
            applicationVersion = vk.API_VERSION_1_0,
            pEngineName = "pbr",
            engineVersion = vk.API_VERSION_1_0,
            apiVersion = vk.API_VERSION_1_3,
        }

        when VULKAN_DEBUG {
            create_info := vk.InstanceCreateInfo {
                sType = .INSTANCE_CREATE_INFO,
                pApplicationInfo = &app_info,
                enabledExtensionCount = u32(len(instance_extensions)),
                ppEnabledExtensionNames = raw_data(instance_extensions[:]),

                enabledLayerCount = u32(len(instance_layers)),
                ppEnabledLayerNames = raw_data(instance_layers[:]),
            }

            debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
                sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                messageSeverity = {.VERBOSE, .ERROR, .WARNING, .INFO},
                messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
                pfnUserCallback = vulkan_debug_callback,
                pUserData = vulkan,
            }

            validation_enabled := [?]vk.ValidationFeatureEnableEXT {
                .BEST_PRACTICES,
                .SYNCHRONIZATION_VALIDATION,
            }

            validation_info := vk.ValidationFeaturesEXT {
                sType = .VALIDATION_FEATURES_EXT,
                enabledValidationFeatureCount = u32(len(validation_enabled)),
                pEnabledValidationFeatures = raw_data(validation_enabled[:]),
            }

            create_info.pNext = &debug_info
            debug_info.pNext = &validation_info
        } else {
            create_info := vk.InstanceCreateInfo {
                sType = .INSTANCE_CREATE_INFO,
                pApplicationInfo = &app_info,
                enabledExtensionCount = u32(len(instance_extensions)),
                ppEnabledExtensionNames = raw_data(instance_extensions),
            }
        }

        vk.CreateInstance(&create_info, nil, &instance) or_return
        vk.load_proc_addresses_instance(instance)
    }

    {
        count := u32(16)
        physical_devices_array: [16]vk.PhysicalDevice
        vk.EnumeratePhysicalDevices(instance, &count, raw_data(physical_devices_array[:])) or_return
        physical_devices := physical_devices_array[0:int(count)]

        #reverse for pd in physical_devices {
            physical_device_properties.sType = .PHYSICAL_DEVICE_PROPERTIES_2
            physical_device_properties.pNext = &physical_device_vulkan_11_properties
            physical_device_vulkan_11_properties.sType = .PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES
            physical_device_vulkan_11_properties.pNext = &physical_device_vulkan_12_properties
            physical_device_vulkan_12_properties.sType = .PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES
            physical_device_vulkan_12_properties.pNext = &physical_device_vulkan_13_properties
            physical_device_vulkan_13_properties.sType = .PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES
            physical_device_vulkan_13_properties.pNext = &physical_device_extended_dynamic_state_3_properties
            physical_device_extended_dynamic_state_3_properties.sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_PROPERTIES_EXT

            vk.GetPhysicalDeviceProperties2(pd, &physical_device_properties)
            if (physical_device_properties.properties.deviceType == .DISCRETE_GPU) {
                physical_device = pd
                break
            }
        }
    }

    // NOTE: The only reason to use vk.GetPhysicalDeviceMemoryProperties2 is to use VK_EXT_memory_budget, which I'm not sure I'll need yet.
    vk.GetPhysicalDeviceMemoryProperties(physical_device, &physical_device_memory_properties)

    physical_device_features.sType = .PHYSICAL_DEVICE_FEATURES_2
    physical_device_features.pNext = &physical_device_vulkan_11_features
    physical_device_vulkan_11_features.sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    physical_device_vulkan_11_features.pNext = &physical_device_vulkan_12_features
    physical_device_vulkan_12_features.sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    physical_device_vulkan_12_features.pNext = &physical_device_vulkan_13_features
    physical_device_vulkan_13_features.sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    physical_device_vulkan_13_features.pNext = &physical_device_extended_dynamic_state_3_features
    physical_device_extended_dynamic_state_3_features.sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT
    physical_device_extended_dynamic_state_3_features.pNext = &physical_device_vertex_input_dynamic_state_features
    physical_device_vertex_input_dynamic_state_features.sType = .PHYSICAL_DEVICE_VERTEX_INPUT_DYNAMIC_STATE_FEATURES_EXT
    vk.GetPhysicalDeviceFeatures2(physical_device, &physical_device_features)

    // TODO: Which features should I use?

    when !VULKAN_DEBUG {
        physical_device_features.features.robustBufferAccess = false
    }
    physical_device_features.features.fullDrawIndexUint32 = false
    physical_device_features.features.imageCubeArray = false
    physical_device_features.features.independentBlend = false
    physical_device_features.features.geometryShader = false
    if !physical_device_features.features.tessellationShader {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.sampleRateShading = false
    physical_device_features.features.dualSrcBlend = false
    physical_device_features.features.logicOp = false
    if !physical_device_features.features.multiDrawIndirect {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.drawIndirectFirstInstance = false
    if !physical_device_features.features.depthClamp {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    if !physical_device_features.features.depthBiasClamp {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.fillModeNonSolid = false
    physical_device_features.features.depthBounds = false
    physical_device_features.features.wideLines = false
    physical_device_features.features.largePoints = false
    physical_device_features.features.alphaToOne = false
    physical_device_features.features.multiViewport = false
    if !physical_device_features.features.samplerAnisotropy {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.textureCompressionETC2 = false
    physical_device_features.features.textureCompressionASTC_LDR = false
    if !physical_device_features.features.textureCompressionBC {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.occlusionQueryPrecise = false
    physical_device_features.features.pipelineStatisticsQuery = false
    physical_device_features.features.vertexPipelineStoresAndAtomics = false
    physical_device_features.features.fragmentStoresAndAtomics = false
    physical_device_features.features.shaderTessellationAndGeometryPointSize = false
    if !physical_device_features.features.shaderImageGatherExtended {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.shaderStorageImageExtendedFormats = false
    physical_device_features.features.shaderStorageImageMultisample = false
    physical_device_features.features.shaderStorageImageReadWithoutFormat = false
    physical_device_features.features.shaderStorageImageWriteWithoutFormat = false
    physical_device_features.features.shaderUniformBufferArrayDynamicIndexing = false
    if !physical_device_features.features.shaderSampledImageArrayDynamicIndexing {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.shaderStorageBufferArrayDynamicIndexing = false
    physical_device_features.features.shaderStorageImageArrayDynamicIndexing = false
    physical_device_features.features.shaderClipDistance = false
    physical_device_features.features.shaderCullDistance = false
    physical_device_features.features.shaderFloat64 = false
    if !physical_device_features.features.shaderInt64 {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_features.features.shaderInt16 = false
    physical_device_features.features.shaderResourceResidency = false
    physical_device_features.features.shaderResourceMinLod = false
    physical_device_features.features.sparseBinding = false
    physical_device_features.features.sparseResidencyBuffer = false
    physical_device_features.features.sparseResidencyImage2D = false
    physical_device_features.features.sparseResidencyImage3D = false
    physical_device_features.features.sparseResidency2Samples = false
    physical_device_features.features.sparseResidency4Samples = false
    physical_device_features.features.sparseResidency8Samples = false
    physical_device_features.features.sparseResidency16Samples = false
    physical_device_features.features.sparseResidencyAliased = false
    physical_device_features.features.variableMultisampleRate = false
    physical_device_features.features.inheritedQueries = false

    physical_device_vulkan_11_features.storageBuffer16BitAccess = false
    physical_device_vulkan_11_features.uniformAndStorageBuffer16BitAccess = false
    physical_device_vulkan_11_features.storagePushConstant16 = false
    physical_device_vulkan_11_features.storageInputOutput16 = false
    physical_device_vulkan_11_features.multiview = false
    physical_device_vulkan_11_features.multiviewGeometryShader = false
    physical_device_vulkan_11_features.multiviewTessellationShader = false
    physical_device_vulkan_11_features.variablePointersStorageBuffer = false
    physical_device_vulkan_11_features.variablePointers = false
    physical_device_vulkan_11_features.protectedMemory = false
    physical_device_vulkan_11_features.samplerYcbcrConversion = false
    if !physical_device_vulkan_11_features.shaderDrawParameters {
        return .ERROR_FEATURE_NOT_PRESENT
    }

    physical_device_vulkan_12_features.samplerMirrorClampToEdge = false
    if !physical_device_vulkan_12_features.drawIndirectCount {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_12_features.storageBuffer8BitAccess = false
    physical_device_vulkan_12_features.uniformAndStorageBuffer8BitAccess = false
    physical_device_vulkan_12_features.storagePushConstant8 = false
    physical_device_vulkan_12_features.shaderBufferInt64Atomics = false
    physical_device_vulkan_12_features.shaderSharedInt64Atomics = false
    physical_device_vulkan_12_features.shaderFloat16 = false // NOTE: I would use this if my laptop supported it!
    physical_device_vulkan_12_features.shaderInt8 = false
    if !physical_device_vulkan_12_features.descriptorIndexing {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_12_features.shaderInputAttachmentArrayDynamicIndexing = false
    physical_device_vulkan_12_features.shaderUniformTexelBufferArrayDynamicIndexing = false
    physical_device_vulkan_12_features.shaderStorageTexelBufferArrayDynamicIndexing = false
    physical_device_vulkan_12_features.shaderUniformBufferArrayNonUniformIndexing = false
    if !physical_device_vulkan_12_features.shaderSampledImageArrayNonUniformIndexing {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_12_features.shaderStorageBufferArrayNonUniformIndexing = false
    physical_device_vulkan_12_features.shaderStorageImageArrayNonUniformIndexing = false
    physical_device_vulkan_12_features.shaderInputAttachmentArrayNonUniformIndexing = false
    physical_device_vulkan_12_features.shaderUniformTexelBufferArrayNonUniformIndexing = false
    physical_device_vulkan_12_features.shaderStorageTexelBufferArrayNonUniformIndexing = false
    physical_device_vulkan_12_features.descriptorBindingUniformBufferUpdateAfterBind = false
    physical_device_vulkan_12_features.descriptorBindingSampledImageUpdateAfterBind = false
    physical_device_vulkan_12_features.descriptorBindingStorageImageUpdateAfterBind = false
    physical_device_vulkan_12_features.descriptorBindingStorageBufferUpdateAfterBind = false
    physical_device_vulkan_12_features.descriptorBindingUniformTexelBufferUpdateAfterBind = false
    physical_device_vulkan_12_features.descriptorBindingStorageTexelBufferUpdateAfterBind = false
    physical_device_vulkan_12_features.descriptorBindingUpdateUnusedWhilePending = false
    if !physical_device_vulkan_12_features.descriptorBindingPartiallyBound {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    if !physical_device_vulkan_12_features.descriptorBindingVariableDescriptorCount {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    if !physical_device_vulkan_12_features.runtimeDescriptorArray {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_12_features.samplerFilterMinmax = false // NOTE: I would use this if my laptop supported it!
    physical_device_vulkan_12_features.scalarBlockLayout = false
    physical_device_vulkan_12_features.imagelessFramebuffer = false
    physical_device_vulkan_12_features.uniformBufferStandardLayout = false
    physical_device_vulkan_12_features.shaderSubgroupExtendedTypes = false
    physical_device_vulkan_12_features.separateDepthStencilLayouts = false
    physical_device_vulkan_12_features.hostQueryReset = false
    physical_device_vulkan_12_features.timelineSemaphore = false
    if !physical_device_vulkan_12_features.bufferDeviceAddress {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_12_features.bufferDeviceAddressCaptureReplay = false
    physical_device_vulkan_12_features.bufferDeviceAddressMultiDevice = false
    if !physical_device_vulkan_12_features.vulkanMemoryModel {
        return .ERROR_FEATURE_NOT_PRESENT        
    }
    if !physical_device_vulkan_12_features.vulkanMemoryModelDeviceScope {
        return .ERROR_FEATURE_NOT_PRESENT        
    }
    if !physical_device_vulkan_12_features.vulkanMemoryModelAvailabilityVisibilityChains {
        return .ERROR_FEATURE_NOT_PRESENT        
    }
    physical_device_vulkan_12_features.shaderOutputViewportIndex = false
    physical_device_vulkan_12_features.shaderOutputLayer = false
    physical_device_vulkan_12_features.subgroupBroadcastDynamicId = false

    when !VULKAN_DEBUG {
        physical_device_vulkan_13_features.robustImageAccess = false
    }
    physical_device_vulkan_13_features.inlineUniformBlock = false
    physical_device_vulkan_13_features.descriptorBindingInlineUniformBlockUpdateAfterBind = false
    if !physical_device_vulkan_13_features.pipelineCreationCacheControl {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_13_features.privateData = false
    if !physical_device_vulkan_13_features.shaderDemoteToHelperInvocation {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_13_features.shaderTerminateInvocation = false
    if !physical_device_vulkan_13_features.subgroupSizeControl {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_13_features.computeFullSubgroups = false
    if !physical_device_vulkan_13_features.synchronization2 {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_13_features.textureCompressionASTC_HDR = false
    physical_device_vulkan_13_features.shaderZeroInitializeWorkgroupMemory = false
    if !physical_device_vulkan_13_features.dynamicRendering {
        return .ERROR_FEATURE_NOT_PRESENT
    }
    physical_device_vulkan_13_features.shaderIntegerDotProduct = false
    if !physical_device_vulkan_13_features.maintenance4 {
        return .ERROR_FEATURE_NOT_PRESENT
    }

    physical_device_extended_dynamic_state_3_features.extendedDynamicState3TessellationDomainOrigin = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3DepthClampEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3PolygonMode = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3RasterizationSamples = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3SampleMask = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3AlphaToCoverageEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3AlphaToOneEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3LogicOpEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ColorBlendEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ColorBlendEquation = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ColorWriteMask = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3RasterizationStream = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ConservativeRasterizationMode = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ExtraPrimitiveOverestimationSize = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3DepthClipEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3SampleLocationsEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ColorBlendAdvanced = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ProvokingVertexMode = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3LineRasterizationMode = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3LineStippleEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3DepthClipNegativeOneToOne = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ViewportWScalingEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ViewportSwizzle = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3CoverageToColorEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3CoverageToColorLocation = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3CoverageModulationMode = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3CoverageModulationTableEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3CoverageModulationTable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3CoverageReductionMode = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3RepresentativeFragmentTestEnable = false
    physical_device_extended_dynamic_state_3_features.extendedDynamicState3ShadingRateImageEnable = false

    if !physical_device_vertex_input_dynamic_state_features.vertexInputDynamicState {
        return .ERROR_FEATURE_NOT_PRESENT
    }

    {
        // TODO: What about vk.GetPhysicalDeviceQueueFamilyProperties2?
        count: u32;
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, nil)
        queue_family_properties = make([]vk.QueueFamilyProperties, count, arena)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, raw_data(queue_family_properties))
    }

    surface = vulkan_create_surface(vulkan) or_return
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities) or_return
    {
        count: u32
        vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, nil) or_return
        surface_formats = make([]vk.SurfaceFormatKHR, count, arena)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, raw_data(surface_formats)) or_return
    }

    // TODO: Find out if there have been any papers written about queue family properties.
    queue_priorities := [32]f32 {
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    }

    queue_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(queue_family_properties), context.temp_allocator)
    queue_count := 0
    for props, queue_family_idx in queue_family_properties {
        if props.queueCount > 0 {
            append(&queue_infos, vk.DeviceQueueCreateInfo{
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = u32(queue_family_idx),
                queueCount = props.queueCount,
                pQueuePriorities = raw_data(queue_priorities[:]),
            })
            queue_count += int(props.queueCount)
        }
    }

    device_extensions := [?]cstring {
        "VK_KHR_swapchain",
        // NOTE: I would use VK_EXT_mesh_shader if my laptop supported it!
        "VK_EXT_extended_dynamic_state3",
        "VK_EXT_vertex_input_dynamic_state",

        "VK_EXT_image_view_min_lod",

    }

    device_info := vk.DeviceCreateInfo {
        sType = .DEVICE_CREATE_INFO,
        pNext = &physical_device_features,
        queueCreateInfoCount = u32(len(queue_infos)),
        pQueueCreateInfos = raw_data(queue_infos),
        enabledExtensionCount = u32(len(device_extensions)),
        ppEnabledExtensionNames = raw_data(device_extensions[:]),
    }
    vk.CreateDevice(physical_device, &device_info, nil, &device) or_return
    vk.load_proc_addresses_device(device)

    queues = make([]vk.Queue, queue_count, arena)
    queue_array_idx := 0
    for props, queue_family_idx in queue_family_properties {
        for queue_idx in 0..<int(props.queueCount) {
            vk.GetDeviceQueue(device, u32(queue_family_idx), u32(queue_idx), &queues[queue_array_idx])
            queue_array_idx += 1
        }
    }

    // TODO
    graphics_queue = queues[0]
    present_queue = queues[0]

    swapchain_format = surface_formats[0] // TODO
    swapchain_extent = surface_capabilities.currentExtent
    {
        info := vk.SwapchainCreateInfoKHR {
            sType = .SWAPCHAIN_CREATE_INFO_KHR,
            surface = surface,
            minImageCount = min(2, surface_capabilities.maxImageCount), // TODO
            imageFormat = swapchain_format.format,
            imageColorSpace = swapchain_format.colorSpace,
            imageExtent = swapchain_extent,
            imageArrayLayers = 1,
            imageUsage = {.COLOR_ATTACHMENT},
            preTransform = surface_capabilities.currentTransform,
            compositeAlpha = {.OPAQUE},
            presentMode = .FIFO, // TODO
            clipped = true,
        }
        vk.CreateSwapchainKHR(device, &info, nil, &swapchain) or_return
    }
    {
        count: u32
        vk.GetSwapchainImagesKHR(device, swapchain, &count, nil) or_return
        swapchain_images = make([]vk.Image, count, arena)
        vk.GetSwapchainImagesKHR(device, swapchain, &count, raw_data(swapchain_images)) or_return
    }
    swapchain_image_views = make([]vk.ImageView, len(swapchain_images), arena)
    for &swapchain_image_view, i in swapchain_image_views {
        info := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain_images[i],
            viewType = .D2,
            format = swapchain_format.format,
            subresourceRange = {
                aspectMask = {.COLOR}, 
                levelCount = 1, 
                layerCount = 1
            },
        }
        vk.CreateImageView(device, &info, nil, &swapchain_image_view) or_return
    }
    frames = make([]Vulkan_Frame, len(swapchain_images), arena)

    {
        info := vk.CommandPoolCreateInfo {
            sType = .COMMAND_POOL_CREATE_INFO,
            flags = {.TRANSIENT, .RESET_COMMAND_BUFFER},

            // TODO:
            // queueFamilyIndex = 0,
        }    
        vk.CreateCommandPool(device, &info, nil, &command_pool) or_return
    }

    {
        info := vk.CommandBufferAllocateInfo {
            sType = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool = command_pool,
            commandBufferCount = u32(len(frames)),
        }
        command_buffers := make([]vk.CommandBuffer, len(frames), context.temp_allocator)
        vk.AllocateCommandBuffers(device, &info, raw_data(command_buffers)) or_return
        for &frame, i in frames {
            frame.command_buffer = command_buffers[i]
        }
    }
    {
        info := vk.FenceCreateInfo {
            sType = .FENCE_CREATE_INFO,
            flags = {.SIGNALED},
        }
        for &frame in frames {
            vk.CreateFence(device, &info, nil, &frame.fence_in_flight) or_return
        }
    }
    {
        info := vk.SemaphoreCreateInfo {
            sType = .SEMAPHORE_CREATE_INFO,
        }
        for &frame in frames {
            vk.CreateSemaphore(device, &info, nil, &frame.sem_image_available) or_return
            vk.CreateSemaphore(device, &info, nil, &frame.sem_render_finished) or_return
        }
    }

    return .SUCCESS
}

global_trace_ctx: trace.Context

debug_trace_assertion_failure_proc :: proc(prefix, message: string, loc := #caller_location) -> ! {
    runtime.print_caller_location(loc)
    runtime.print_string(" ")
    runtime.print_string(prefix)
    if len(message) > 0 {
        runtime.print_string(": ")
        runtime.print_string(message)
    }
    runtime.print_byte('\n')

    ctx := &global_trace_ctx
    if !trace.in_resolve(ctx) {
        buf: [64]trace.Frame
        runtime.print_string("Debug Trace:\n")
        frames := trace.frames(ctx, 1, buf[:])
        for f, i in frames {
            fl := trace.resolve(ctx, f, context.temp_allocator)
            if fl.loc.file_path == "" && fl.loc.line == 0 {
                continue
            }
            runtime.print_caller_location(fl.loc)
            runtime.print_string(" - frame ")
            runtime.print_int(i)
            runtime.print_byte('\n')
        }
    }
    runtime.trap()
}

vulkan_update :: proc(using vulkan: ^Vulkan) -> vk.Result {
    vk.WaitForFences(device, 1, &frames[current_frame].fence_in_flight, true, max(u64)) or_return
    vk.ResetFences(device, 1, &frames[current_frame].fence_in_flight) or_return

    vk.AcquireNextImageKHR(device, swapchain, max(u64), frames[current_frame].sem_image_available, vk.Fence{}, &image_idx) or_return
    if (image_idx == 0 && staged) 
    {
        app_show()
    }

    cb := frames[current_frame].command_buffer
    {
        info := vk.CommandBufferBeginInfo {
            sType = .COMMAND_BUFFER_BEGIN_INFO,
            flags = {.ONE_TIME_SUBMIT},
        };
        vk.BeginCommandBuffer(cb, &info) or_return
    }

    {
        info := vk.RenderingInfo {
            sType = .RENDERING_INFO,
            
        }
    }

    return .SUCCESS
}

main :: proc() {
    trace.init(&global_trace_ctx)
    context.assertion_failure_proc = debug_trace_assertion_failure_proc

    w, h, refresh_rate := app_init()

    vulkan: Vulkan
    {
        _data := make([]byte, mem.Megabyte)
        _arena := mem.Arena{
            data = _data,
        }
        vulkan.arena = mem.arena_allocator(&_arena)
    }
    if res := vulkan_init(&vulkan); res != .SUCCESS {
        app_panic("Your graphics driver is out of date.")
    }

    for app_update() {
        intrinsics.cpu_relax()

        free_all(context.temp_allocator)
    }
}