/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once
#include "raft/core/resource/cuda_stream.hpp"
#include "thrust/detail/raw_pointer_cast.h"
#include "thrust/detail/tuple.inl"
#include "thrust/iterator/zip_iterator.h"
#include <rmm/device_uvector.hpp>
#include <thrust/device_ptr.h>
#include <cuda_runtime_api.h>
#include <iterator>
#include <raft/core/device_support.hpp>
#include <raft/core/device_type.hpp>
#include <raft/core/resources.hpp>
#include <raft/util/cuda_rt_essentials.hpp>
#include <raft/util/cudart_utils.hpp>
#include <rmm/exec_policy.hpp>
#include <iterator>
#include <thrust/copy.h>
#include <type_traits>

namespace raft {
namespace detail {

template <device_type dst_type, device_type src_type, typename T>
std::enable_if_t<
  std::conjunction_v<std::disjunction<std::bool_constant<dst_type == device_type::gpu>,
                                      std::bool_constant<src_type == device_type::gpu>>,
                     std::bool_constant<CUDA_ENABLED>>,
  void>
copy(raft::resources const& handle, T* dst, T const* src, uint32_t size)
{
  // if (src_type == device_type::cpu) {
  //   raft::update_device(dst, src, size, raft::resource::get_cuda_stream(handle));
  // }
  // else if (dst_type == device_type::cpu) {
  //   raft::update_host(dst, src, size, raft::resource::get_cuda_stream(handle));
  //   cudaDeviceSynchronize();
  // }
  // else {
    // raft::copy_async(dst, src, size, raft::resource::get_cuda_stream(handle));
  // }
  raft::copy(dst, src, size, raft::resource::get_cuda_stream(handle));
}

}  // namespace detail
}  // namespace raft