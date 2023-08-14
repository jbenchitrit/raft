/*
 * Copyright (c) 2018-2023, NVIDIA CORPORATION.
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

#include <raft/core/resource/cublas_handle.hpp>
#include <raft/linalg/gemm.cuh>
#include <raft/stats/mean_center.cuh>

namespace raft {
namespace stats {
namespace detail {
/**
 * @brief Compute covariance of the input matrix
 *
 * Mean operation is assumed to be performed on a given column.
 *
 * @tparam Type the data type
 * @param covar the output covariance matrix
 * @param data the input matrix (this will get mean-centered at the end!)
 * @param mu mean vector of the input matrix
 * @param D number of columns of data
 * @param N number of rows of data
 * @param sample whether to evaluate sample covariance or not. In other words,
 * whether to normalize the output using N-1 or N, for true or false,
 * respectively
 * @param rowMajor whether the input data is row or col major
 * @param stable whether to run the slower-but-numerically-stable version or not
 * @param handle cublas handle
 * @param stream cuda stream
 * @note if stable=true, then the input data will be mean centered after this
 * function returns!
 */
template <typename Type>
void cov(raft::resources const& handle,
         Type* covar,
         Type* data,
         const Type* mu,
         std::size_t D,
         std::size_t N,
         bool sample,
         bool rowMajor,
         bool stable,
         cudaStream_t stream)
{
  if (stable) {
    // since mean operation is assumed to be along a given column, broadcast
    // must be along rows!
    raft::stats::meanCenter(data, data, mu, D, N, rowMajor, true, stream);
    Type alpha = Type(1) / (sample ? Type(N - 1) : Type(N));
    Type beta  = Type(0);
    auto ldd   = rowMajor ? D : N;
    linalg::gemm(
      handle, !rowMajor, rowMajor, D, D, N, &alpha, data, ldd, data, ldd, &beta, covar, D, stream);
  } else {
    ///@todo: implement this using cutlass + customized epilogue!
    ASSERT(false, "cov: Implement stable=false case!");
  }
  RAFT_CUDA_TRY(cudaPeekAtLastError());
}
};  // end namespace detail
};  // end namespace stats
};  // end namespace raft
