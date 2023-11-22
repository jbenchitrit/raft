/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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

#include <cstdint>
#include <raft/core/pinned_mdspan.hpp>
#include <raft/core/resources.hpp>

#include <raft/core/mdarray.hpp>
#include <raft/core/pinned_container_policy.hpp>

namespace raft {
/**
 * @brief mdarray with pinned container policy
 * @tparam ElementType the data type of the elements
 * @tparam Extents defines the shape
 * @tparam LayoutPolicy policy for indexing strides and layout ordering
 * @tparam ContainerPolicy storage and accessor policy
 */
template <typename ElementType,
          typename Extents,
          typename LayoutPolicy    = layout_c_contiguous,
          typename ContainerPolicy = pinned_vector_policy<ElementType>>
using pinned_mdarray =
  mdarray<ElementType, Extents, LayoutPolicy, pinned_accessor<ContainerPolicy>>;

/**
 * @brief Shorthand for 0-dim pinned mdarray (scalar).
 * @tparam ElementType the data type of the scalar element
 * @tparam IndexType the index type of the extents
 */
template <typename ElementType, typename IndexType = std::uint32_t>
using pinned_scalar = pinned_mdarray<ElementType, scalar_extent<IndexType>>;

/**
 * @brief Shorthand for 1-dim pinned mdarray.
 * @tparam ElementType the data type of the vector elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous>
using pinned_vector = pinned_mdarray<ElementType, vector_extent<IndexType>, LayoutPolicy>;

/**
 * @brief Shorthand for c-contiguous pinned matrix.
 * @tparam ElementType the data type of the matrix elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous>
using pinned_matrix = pinned_mdarray<ElementType, matrix_extent<IndexType>, LayoutPolicy>;

/**
 * @defgroup pinned_mdarray_factories factories to create pinned mdarrays
 * @{
 */

/**
 * @brief Create a pinned mdarray.
 * @tparam ElementType the data type of the matrix elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 * @param[in] res raft handle for managing expensive resources
 * @param[in] exts dimensionality of the array (series of integers)
 * @return raft::pinned_mdarray
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous,
          size_t... Extents>
auto make_pinned_mdarray(raft::resources& res, extents<IndexType, Extents...> exts)
{
  using mdarray_t = pinned_mdarray<ElementType, decltype(exts), LayoutPolicy>;

  typename mdarray_t::mapping_type layout{exts};
  typename mdarray_t::container_policy_type policy;

  return mdarray_t{res, layout, policy};
}

/**
 * @}
 */

/**
 * @brief Create a pinned mdarray.
 * @tparam ElementType the data type of the matrix elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 * @param exts dimensionality of the array (series of integers)
 * Note: This function is deprecated and will be removed in a future version. Please use version
 * that accepts raft::resources.
 *
 * @return raft::pinned_mdarray
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous,
          size_t... Extents>
auto make_pinned_mdarray(extents<IndexType, Extents...> exts)
{
  using mdarray_t = pinned_mdarray<ElementType, decltype(exts), LayoutPolicy>;

  typename mdarray_t::mapping_type layout{exts};
  typename mdarray_t::container_policy_type policy;

  raft::resources res;
  return mdarray_t{res, layout, policy};
}

/**
 * @ingroup pinned_mdarray_factories
 * @brief Create a 2-dim c-contiguous pinned mdarray.
 * @tparam ElementType the data type of the matrix elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 * @param[in] res raft handle for managing expensive resources
 * @param[in] n_rows number or rows in matrix
 * @param[in] n_cols number of columns in matrix
 * @return raft::pinned_matrix
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous>
auto make_pinned_matrix(raft::resources& res, IndexType n_rows, IndexType n_cols)
{
  return make_pinned_mdarray<ElementType, IndexType, LayoutPolicy>(
    res, make_extents<IndexType>(n_rows, n_cols));
}

/**
 * @ingroup pinned_mdarray_factories
 * @brief Create a pinned scalar from v.
 *
 * @tparam ElementType the data type of the scalar element
 * @tparam IndexType the index type of the extents
 * @param[in] res raft handle for managing expensive resources
 * @param[in] v scalar type to wrap
 * @return raft::pinned_scalar
 */
template <typename ElementType, typename IndexType = std::uint32_t>
auto make_pinned_scalar(raft::resources& res, ElementType const& v)
{
  // FIXME(jiamingy): We can optimize this by using std::array as container policy, which
  // requires some more compile time dispatching. This is enabled in the ref impl but
  // hasn't been ported here yet.
  scalar_extent<IndexType> extents;
  using policy_t = typename pinned_scalar<ElementType>::container_policy_type;
  policy_t policy;
  auto scalar = pinned_scalar<ElementType>{res, extents, policy};
  scalar(0)   = v;
  return scalar;
}

/**
 * @brief Create a pinned scalar from v.
 *
 * @tparam ElementType the data type of the scalar element
 * @tparam IndexType the index type of the extents
 * @param[in] v scalar type to wrap
 * Note: This function is deprecated and will be removed in a future version. Please use version
 * that accepts raft::resources.
 *
 * @return raft::pinned_scalar
 */
template <typename ElementType, typename IndexType = std::uint32_t>
auto make_pinned_scalar(ElementType const& v)
{
  // FIXME(jiamingy): We can optimize this by using std::array as container policy, which
  // requires some more compile time dispatching. This is enabled in the ref impl but
  // hasn't been ported here yet.
  scalar_extent<IndexType> extents;
  using policy_t = typename pinned_scalar<ElementType>::container_policy_type;
  policy_t policy;
  raft::resources handle;
  auto scalar = pinned_scalar<ElementType>{handle, extents, policy};
  scalar(0)   = v;
  return scalar;
}

/**
 * @ingroup pinned_mdarray_factories
 * @brief Create a 1-dim pinned mdarray.
 * @tparam ElementType the data type of the vector elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 * @param[in] res raft handle for managing expensive resources
 * @param[in] n number of elements in vector
 * @return raft::pinned_vector
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous>
auto make_pinned_vector(raft::resources& res, IndexType n)
{
  return make_pinned_mdarray<ElementType, IndexType, LayoutPolicy>(res, make_extents<IndexType>(n));
}

/**
 * @brief Create a 1-dim pinned mdarray.
 * @tparam ElementType the data type of the vector elements
 * @tparam IndexType the index type of the extents
 * @tparam LayoutPolicy policy for strides and layout ordering
 * @param[in] n number of elements in vector
 *
 * Note: This function is deprecated and will be removed in a future version. Please use version
 * that accepts raft::resources.
 * @return raft::pinned_vector
 */
template <typename ElementType,
          typename IndexType    = std::uint32_t,
          typename LayoutPolicy = layout_c_contiguous>
auto make_pinned_vector(IndexType n)
{
  return make_pinned_mdarray<ElementType, IndexType, LayoutPolicy>(make_extents<IndexType>(n));
}

}  // end namespace raft
