package pbr

import vk "vendor:vulkan"
import "core:mem"
import "core:slice"

// TODO: Add support for Vulkan 1.0.

@(private="file")
Vulkan_Unallocated_Buffer :: struct {
	buffer: vk.Buffer,
	memory_properties_include, memory_properties_exclude: vk.MemoryPropertyFlags,
}

@(private="file")
Vulkan_Unallocated_Image :: struct {
	image: vk.Image,
	memory_properties_include, memory_properties_exclude: vk.MemoryPropertyFlags,
}

@(private="file")
Vulkan_Allocation :: struct {
	memory: vk.DeviceMemory,
	offset: vk.DeviceSize,
}

Vulkan_Allocator :: struct {
	buffer_allocations: map[vk.Buffer]Vulkan_Allocation,
	image_allocations: map[vk.Image]Vulkan_Allocation,
	unallocated_buffers: [dynamic]Vulkan_Unallocated_Buffer,
	unallocated_images: [dynamic]Vulkan_Unallocated_Image,
}

vulkan_create_allocator :: proc() -> (allocator: Vulkan_Allocator) {
	allocator.buffer_allocations = make(map[vk.Buffer]Vulkan_Allocation)
	allocator.image_allocations = make(map[vk.Image]Vulkan_Allocation)
	allocator.unallocated_buffers = make([dynamic]Vulkan_Unallocated_Buffer)
	allocator.unallocated_images = make([dynamic]Vulkan_Unallocated_Image)
	return
}

vulkan_create_buffer :: proc(
	using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, 
	size: vk.DeviceSize, usage: vk.BufferUsageFlags, 
	memory_properties_include, memory_properties_exclude: vk.MemoryPropertyFlags,
	loc := #caller_location) -> (buffer: vk.Buffer) 
{
	info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
	}
	res := vk.CreateBuffer(device, &info, nil, &buffer)
	ensure(res == .SUCCESS, loc=loc)

	append(&unallocated_buffers, Vulkan_Unallocated_Buffer{buffer, memory_properties_include, memory_properties_exclude})
	return
}

vulkan_create_image :: proc(
	using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, 
	format: vk.Format, 
	width, height, depth, mip_levels, array_layers: u32, 
	samples: vk.SampleCountFlags, 
	usage: vk.ImageUsageFlags, 
	initial_layout: vk.ImageLayout, 
	memory_properties_include, memory_properties_exclude: vk.MemoryPropertyFlags,
	loc := #caller_location) -> (image: vk.Image, result: vk.Result) 
{
	image_type: vk.ImageType = .D1
	height := height > 1 ? height : 1
	depth := depth > 1 ? depth : 1
	if height != 1 {
		image_type = .D2
	}
	if depth != 1 { 
		image_type = .D3
	}
	info := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO,
		imageType = image_type,
		format = format,
		extent = {width, height, 1},
		mipLevels = mip_levels,
		arrayLayers = array_layers,
		samples = samples,
		tiling = .OPTIMAL,
		usage = usage,
		initialLayout = initial_layout,
	}
	res := vk.CreateImage(device, &info, nil, &image)
	ensure(res == .SUCCESS, loc=loc)

	append(&unallocated_images, Vulkan_Unallocated_Image{image, memory_properties_include, memory_properties_exclude})
	return
}

vulkan_alloc :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator) -> vk.Result {
	if len(unallocated_buffers) == 0 && len(unallocated_images) == 0 {
		return .SUCCESS
	}

	bind_buffer_memory_infos := make([dynamic]vk.BindBufferMemoryInfo, 0, len(unallocated_buffers), context.temp_allocator)
	bind_image_memory_infos := make([dynamic]vk.BindImageMemoryInfo, 0, len(unallocated_images), context.temp_allocator)

	memory_types := physical_device_memory_properties.memoryTypes[0:int(physical_device_memory_properties.memoryTypeCount)]

	buffer_memory_requirements := make([dynamic]vk.MemoryRequirements2, len(unallocated_buffers), context.temp_allocator)
	for buffer_index := 0; buffer_index < len(unallocated_buffers); buffer_index += 1 {
		buffer_dedicated_memory_requirements := vk.MemoryDedicatedRequirements{
			sType = .MEMORY_DEDICATED_REQUIREMENTS,
		}
		buffer_memory_requirements[buffer_index].sType = .MEMORY_REQUIREMENTS_2
		buffer_memory_requirements[buffer_index].pNext = &buffer_dedicated_memory_requirements
		info := vk.BufferMemoryRequirementsInfo2{
			sType = .BUFFER_MEMORY_REQUIREMENTS_INFO_2,
			buffer = unallocated_buffers[buffer_index].buffer,
		}
		vk.GetBufferMemoryRequirements2(device, &info, &buffer_memory_requirements[buffer_index])

		if buffer_dedicated_memory_requirements.prefersDedicatedAllocation || buffer_dedicated_memory_requirements.requiresDedicatedAllocation {
			memory_dedicated_allocate_info := vk.MemoryDedicatedAllocateInfo{
				sType = .MEMORY_DEDICATED_ALLOCATE_INFO,
				buffer = unallocated_buffers[buffer_index].buffer,
			}
			memory_allocate_info := vk.MemoryAllocateInfo{
				sType = .MEMORY_ALLOCATE_INFO,
				pNext = &memory_dedicated_allocate_info,
				allocationSize = buffer_memory_requirements[buffer_index].memoryRequirements.size,
				memoryTypeIndex = max(u32),
			}
			for memory_type, memory_type_index in memory_types {
				memory_type_bit := u32(1 << u32(memory_type_index))
				memory_type_bits := buffer_memory_requirements[buffer_index].memoryRequirements.memoryTypeBits
				memory_properties_include := unallocated_buffers[buffer_index].memory_properties_include
				memory_properties_exclude := unallocated_buffers[buffer_index].memory_properties_exclude
				memory_properties := memory_type.propertyFlags

				if memory_type_bits & memory_type_bit != 0 && memory_properties_include <= memory_properties && !(memory_properties_exclude <= memory_properties) {
					memory_allocate_info.memoryTypeIndex = u32(memory_type_index)
					break
				}
			}
			ensure(memory_allocate_info.memoryTypeIndex != max(u32))

			memory: vk.DeviceMemory = ---
			if res := vk.AllocateMemory(device, &memory_allocate_info, nil, &memory); res != .SUCCESS {
				if res == .ERROR_OUT_OF_DEVICE_MEMORY {
					panic("Ran out of GPU memory.")
				} else {
					return res
				}
			}
			buffer_allocations[unallocated_buffers[buffer_index].buffer] = {memory, 0}

			bind_buffer_memory_info := vk.BindBufferMemoryInfo{
				sType = .BIND_BUFFER_MEMORY_INFO,
				buffer = unallocated_buffers[buffer_index].buffer,
				memory = memory,
			}
			append(&bind_buffer_memory_infos, bind_buffer_memory_info)

			ordered_remove(&unallocated_buffers, buffer_index)
			ordered_remove(&buffer_memory_requirements, buffer_index)
			buffer_index -= 1
		}
	}

	image_memory_requirements := make([dynamic]vk.MemoryRequirements2, len(unallocated_images), context.temp_allocator)
	for image_index := 0; image_index < len(unallocated_images); image_index += 1 {
		image_dedicated_memory_requirements := vk.MemoryDedicatedRequirements{
			sType = .MEMORY_DEDICATED_REQUIREMENTS,
		}
		image_memory_requirements[image_index].sType = .MEMORY_REQUIREMENTS_2
		image_memory_requirements[image_index].pNext = &image_dedicated_memory_requirements
		info := vk.ImageMemoryRequirementsInfo2{
			sType = .IMAGE_MEMORY_REQUIREMENTS_INFO_2,
			image = unallocated_images[image_index].image,
		}
		vk.GetImageMemoryRequirements2(device, &info, &image_memory_requirements[image_index])

		if image_dedicated_memory_requirements.prefersDedicatedAllocation || image_dedicated_memory_requirements.requiresDedicatedAllocation {
			memory_dedicated_allocate_info := vk.MemoryDedicatedAllocateInfo{
				sType = .MEMORY_DEDICATED_ALLOCATE_INFO,
				image = unallocated_images[image_index].image,
			}
			memory_allocate_info := vk.MemoryAllocateInfo{
				sType = .MEMORY_ALLOCATE_INFO,
				pNext = &memory_dedicated_allocate_info,
				allocationSize = image_memory_requirements[image_index].memoryRequirements.size,
				memoryTypeIndex = max(u32),
			}
			for memory_type, memory_type_index in memory_types {
				memory_type_bit := u32(1 << u32(memory_type_index))
				memory_type_bits := image_memory_requirements[image_index].memoryRequirements.memoryTypeBits
				memory_properties_include := unallocated_images[image_index].memory_properties_include
				memory_properties_exclude := unallocated_images[image_index].memory_properties_exclude
				memory_properties := memory_type.propertyFlags

				if memory_type_bits & memory_type_bit != 0 && memory_properties_include <= memory_properties && !(memory_properties_exclude <= memory_properties) {
					memory_allocate_info.memoryTypeIndex = u32(memory_type_index)
					break
				}
			}
			ensure(memory_allocate_info.memoryTypeIndex != max(u32))

			memory: vk.DeviceMemory = ---
			if res := vk.AllocateMemory(device, &memory_allocate_info, nil, &memory); res != .SUCCESS {
				if res == .ERROR_OUT_OF_DEVICE_MEMORY {
					panic("Ran out of GPU memory.")
				} else {
					return res
				}
			}
			image_allocations[unallocated_images[image_index].image] = {memory, 0}

			bind_image_memory_info := vk.BindImageMemoryInfo{
				sType = .BIND_IMAGE_MEMORY_INFO,
				image = unallocated_images[image_index].image,
				memory = memory,
			}
			append(&bind_image_memory_infos, bind_image_memory_info)

			ordered_remove(&unallocated_images, image_index)
			ordered_remove(&image_memory_requirements, image_index)
			image_index -= 1
		}
	}

	for len(unallocated_buffers) > 0 || len(unallocated_images) > 0 {
		assert(len(unallocated_buffers) == len(buffer_memory_requirements))
		assert(len(unallocated_images) == len(image_memory_requirements))

		max_count := 0
		max_index := -1
		for memory_type, memory_type_index in memory_types {
			count := 0
			memory_type_bit := u32(1 << u32(memory_type_index))

			for buffer_index := 0; buffer_index < len(unallocated_buffers); buffer_index += 1 {
				memory_type_bits := buffer_memory_requirements[buffer_index].memoryRequirements.memoryTypeBits
				memory_properties_include := unallocated_buffers[buffer_index].memory_properties_include
				memory_properties_exclude := unallocated_buffers[buffer_index].memory_properties_exclude
				memory_properties := memory_type.propertyFlags

				if memory_type_bits & memory_type_bit != 0 && memory_properties_include <= memory_properties && !(memory_properties_exclude <= memory_properties) {
					count += 1
				}
			}

			for image_index := 0; image_index < len(unallocated_images); image_index += 1 {
				memory_type_bits := image_memory_requirements[image_index].memoryRequirements.memoryTypeBits
				memory_properties_include := unallocated_images[image_index].memory_properties_include
				memory_properties_exclude := unallocated_images[image_index].memory_properties_exclude
				memory_properties := memory_type.propertyFlags

				if memory_type_bits & memory_type_bit != 0 && memory_properties_include <= memory_properties && !(memory_properties_exclude <= memory_properties) {
					count += 1
				}
			}

			if count > max_count {
				max_count = count
				max_index = memory_type_index
			}
		}

		memory_type_index := max_index
		memory_type := memory_types[memory_type_index]
		memory_type_bit := u32(1 << u32(memory_type_index))

		memory_offset := vk.DeviceSize(0)

		bind_buffer_memory_info_start_index := len(bind_buffer_memory_infos)
		bind_image_memory_info_start_index := len(bind_image_memory_infos)

		for buffer_index := 0; buffer_index < len(unallocated_buffers); buffer_index += 1 {
			memory_type_bits := buffer_memory_requirements[buffer_index].memoryRequirements.memoryTypeBits
			memory_properties_include := unallocated_buffers[buffer_index].memory_properties_include
			memory_properties_exclude := unallocated_buffers[buffer_index].memory_properties_exclude

			if memory_type_bits & memory_type_bit != 0 && memory_properties_include <= memory_type.propertyFlags && !(memory_properties_exclude <= memory_type.propertyFlags) {
				memory_offset = align_forward_device_size(memory_offset, buffer_memory_requirements[buffer_index].memoryRequirements.alignment)

				bind_buffer_memory_info := vk.BindBufferMemoryInfo{
					sType = .BIND_BUFFER_MEMORY_INFO,
					buffer = unallocated_buffers[buffer_index].buffer,
					memoryOffset = memory_offset,
				}
				append(&bind_buffer_memory_infos, bind_buffer_memory_info)

				memory_offset += buffer_memory_requirements[buffer_index].memoryRequirements.size

				ordered_remove(&unallocated_buffers, buffer_index)
				ordered_remove(&buffer_memory_requirements, buffer_index)
				buffer_index -= 1
			}
		}

		for image_index := 0; image_index < len(unallocated_images); image_index += 1 {
			memory_type_bits := image_memory_requirements[image_index].memoryRequirements.memoryTypeBits
			memory_properties_include := unallocated_images[image_index].memory_properties_include
			memory_properties_exclude := unallocated_images[image_index].memory_properties_exclude

			if memory_type_bits & memory_type_bit != 0 && memory_properties_include <= memory_type.propertyFlags && !(memory_properties_exclude <= memory_type.propertyFlags) {
				memory_offset = align_forward_device_size(memory_offset, image_memory_requirements[image_index].memoryRequirements.alignment)

				bind_image_memory_info := vk.BindImageMemoryInfo{
					sType = .BIND_IMAGE_MEMORY_INFO,
					image = unallocated_images[image_index].image,
					memoryOffset = memory_offset,
				}
				append(&bind_image_memory_infos, bind_image_memory_info)

				memory_offset += image_memory_requirements[image_index].memoryRequirements.size

				ordered_remove(&unallocated_images, image_index)
				ordered_remove(&image_memory_requirements, image_index)
				image_index -= 1
			}
		}

		memory_allocate_info := vk.MemoryAllocateInfo{
			sType = .MEMORY_ALLOCATE_INFO,
			memoryTypeIndex = u32(memory_type_index),
			allocationSize = memory_offset,
		}
		memory: vk.DeviceMemory = ---
		if res := vk.AllocateMemory(device, &memory_allocate_info, nil, &memory); res != .SUCCESS {
			if res == .ERROR_OUT_OF_DEVICE_MEMORY {
				panic("Ran out of GPU memory.")
			} else {
				return res
			}
		}

		if bind_buffer_memory_info_start_index != len(bind_buffer_memory_infos) {
			for &b in bind_buffer_memory_infos[bind_buffer_memory_info_start_index:] {
				b.memory = memory
				buffer_allocations[b.buffer] = {memory, b.memoryOffset}
			}
		}
		if bind_image_memory_info_start_index != len(bind_image_memory_infos) {
			for &b in bind_image_memory_infos[bind_image_memory_info_start_index:] {
				b.memory = memory
				image_allocations[b.image] = {memory, b.memoryOffset}
			}
		}
	}

	assert(len(unallocated_buffers) == len(buffer_memory_requirements))
	assert(len(unallocated_images) == len(image_memory_requirements))

	if len(bind_buffer_memory_infos) > 0 {
		vk.BindBufferMemory2(device, u32(len(bind_buffer_memory_infos)), raw_data(bind_buffer_memory_infos)) or_return
	}
	if len(bind_image_memory_infos) > 0 {
		vk.BindImageMemory2(device, u32(len(bind_image_memory_infos)), raw_data(bind_image_memory_infos)) or_return
	}

	return .SUCCESS
}

vulkan_free_buffer :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, buffer: vk.Buffer, loc := #caller_location) {
	buffer_allocations_len := len(buffer_allocations)
	if buffer_allocations_len == 0 {
		return
	}

	allocation := vulkan_get_allocation(allocator, buffer)
	delete_key(&buffer_allocations, buffer)

	if buffer_allocations_len == 1 {
		vk.FreeMemory(device, allocation.memory, nil)
	}

	return
}

vulkan_free_image :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, image: vk.Image) {
	image_allocations_len := len(image_allocations)
	if image_allocations_len == 0 {
		return
	}

	allocation := vulkan_get_allocation(allocator, image)	
	delete_key(&image_allocations, image)

	if image_allocations_len == 1 {
		vk.FreeMemory(device, allocation.memory, nil)
	}

	return
}

vulkan_free :: proc{vulkan_free_buffer, vulkan_free_image}

@(private="file")
is_power_of_two_device_size :: #force_inline proc(x: vk.DeviceSize) -> bool {
	if x <= 0 {
		return false
	}
	return (x & (x-1)) == 0
}

@(private="file")
align_forward_device_size :: #force_inline proc(ptr, align: vk.DeviceSize) -> vk.DeviceSize {
	assert(is_power_of_two_device_size(align))

	p := ptr
	modulo := p & (align-1)
	if modulo != 0 {
		p += align - modulo
	}
	return p
}

@(private="file")
vulkan_get_allocation_buffer :: proc(using allocator: ^Vulkan_Allocator, buffer: vk.Buffer,
	loc := #caller_location) -> (allocation: Vulkan_Allocation) {
	ok: bool
	allocation, ok = buffer_allocations[buffer]
	assert(ok, loc=loc)
	return
}

@(private="file")
vulkan_get_allocation_image :: proc(using allocator: ^Vulkan_Allocator, image: vk.Image,
	loc := #caller_location) -> (allocation: Vulkan_Allocation) {
	ok: bool
	allocation, ok = image_allocations[image]
	assert(ok, loc=loc)
	return
}

@(private="file")
vulkan_get_allocation :: proc{vulkan_get_allocation_buffer, vulkan_get_allocation_image}

vulkan_map_memory_buffer :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, 
	buffer: vk.Buffer, offset, size: vk.DeviceSize,
	loc := #caller_location) -> (data: []byte) {
	allocation := vulkan_get_allocation(allocator, buffer)
	raw := mem.Raw_Slice{len = int(size)}
	res := vk.MapMemory(device, allocation.memory, allocation.offset + offset, size, {}, &raw.data)
	ensure(res == .SUCCESS, loc=loc)
	data = transmute([]byte)raw
	return
}

vulkan_map_memory_image :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, 
	image: vk.Image, offset, size: vk.DeviceSize,
	loc := #caller_location) -> (data: []byte) {
	allocation := vulkan_get_allocation(allocator, image)
	raw := mem.Raw_Slice{len = int(size)}
	res := vk.MapMemory(device, allocation.memory, allocation.offset + offset, size, {}, &raw.data)
	ensure(res == .SUCCESS, loc=loc)
	data = transmute([]byte)raw
	return
}

vulkan_map_memory :: proc{vulkan_map_memory_buffer, vulkan_map_memory_image}

vulkan_unmap_memory_buffer :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, buffer: vk.Buffer) {
	allocation := vulkan_get_allocation(allocator, buffer)
	vk.UnmapMemory(device, allocation.memory)
}

vulkan_unmap_memory_image :: proc(using vulkan: ^Vulkan, using allocator: ^Vulkan_Allocator, image: vk.Image) {
	allocation := vulkan_get_allocation(allocator, image)
	vk.UnmapMemory(device, allocation.memory)
}

vulkan_unmap_memory :: proc{vulkan_unmap_memory_buffer, vulkan_unmap_memory_image}