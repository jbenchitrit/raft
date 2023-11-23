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

#include <raft/comms/std_comms.hpp>
#include <raft/core/device_mdarray.hpp>
#include <raft/core/host_mdarray.hpp>
#include <raft/core/resources.hpp>
#include <raft/neighbors/ann_types.hpp>

#undef RAFT_EXPLICIT_INSTANTIATE_ONLY
#include <raft/neighbors/brute_force.cuh>
#include <raft/neighbors/ivf_flat.cuh>
#include <raft/neighbors/ivf_pq.cuh>
#define RAFT_EXPLICIT_INSTANTIATE_ONLY

// Number of rows per batch (search on shards)
#define N_ROWS_PER_BATCH 33554432 // 2**25

namespace raft::neighbors::mg {
enum dist_mode { SHARDING, INDEX_DUPLICATION };
}

namespace raft::neighbors::mg::detail {
using namespace raft::neighbors;

template <typename AnnIndexType, typename T, typename IdxT>
class ann_interface {
 public:
  void build(raft::resources const& handle,
             const ann::index_params* index_params,
             raft::host_matrix_view<const T, IdxT, row_major> h_index_dataset)
  {
    auto index_dataset_view = store_to_device(handle, index_dataset_, h_index_dataset);

    if constexpr (std::is_same<AnnIndexType, ivf_flat::index<T, IdxT>>::value) {
      index_.emplace(std::move(ivf_flat::build<T, IdxT>(
        handle, *static_cast<const ivf_flat::index_params*>(index_params), index_dataset_view)));
    } else if constexpr (std::is_same<AnnIndexType, ivf_pq::index<IdxT>>::value) {
      index_.emplace(std::move(ivf_pq::build<T>(
        handle, *static_cast<const ivf_pq::index_params*>(index_params), index_dataset_view)));
    }
  }

  void extend(raft::resources const& handle,
              raft::host_matrix_view<const T, IdxT, row_major> h_new_vectors,
              std::optional<raft::host_vector_view<const IdxT, IdxT>> h_new_indices)
  {
    index_dataset_.reset();
    new_vectors_.reset();
    new_indices_.reset();

    auto new_vectors_view = store_to_device(handle, new_vectors_, h_new_vectors);

    std::optional<raft::device_vector_view<const IdxT, IdxT>> new_indices_opt = std::nullopt;
    if (h_new_indices) {
      new_indices_opt = store_to_device(handle, new_indices_, h_new_indices.value());
    }

    if constexpr (std::is_same<AnnIndexType, ivf_flat::index<T, IdxT>>::value) {
      index_.emplace(std::move(
        ivf_flat::extend<T, IdxT>(handle, new_vectors_view, new_indices_opt, index_.value())));
    } else if constexpr (std::is_same<AnnIndexType, ivf_pq::index<IdxT>>::value) {
      index_.emplace(std::move(
        ivf_pq::extend<T, IdxT>(handle, new_vectors_view, new_indices_opt, index_.value())));
    }
  }

  void search_impl(raft::resources const& handle,
                   const ann::search_params* search_params,
                   raft::device_matrix_view<const T, IdxT, row_major> query_dataset,
                   raft::device_matrix_view<IdxT, IdxT, row_major> neighbors,
                   raft::device_matrix_view<float, IdxT, row_major> distances)
  {
    if constexpr (std::is_same<AnnIndexType, ivf_flat::index<T, IdxT>>::value) {
      ivf_flat::search<T, IdxT>(handle,
                                *reinterpret_cast<const ivf_flat::search_params*>(search_params),
                                index_.value(),
                                query_dataset,
                                neighbors,
                                distances);
    } else if constexpr (std::is_same<AnnIndexType, ivf_pq::index<IdxT>>::value) {
      ivf_pq::search<T, IdxT>(handle,
                              *reinterpret_cast<const ivf_pq::search_params*>(search_params),
                              index_.value(),
                              query_dataset,
                              neighbors,
                              distances);
    }
  }

  // Index duplication, results stored on host memory without merge
  void search(raft::resources const& handle,
              const ann::search_params* search_params,
              raft::host_matrix_view<const T, IdxT, row_major> h_query_dataset,
              raft::host_matrix_view<IdxT, IdxT, row_major> h_neighbors,
              raft::host_matrix_view<float, IdxT, row_major> h_distances)
  {
    index_dataset_.reset();
    new_vectors_.reset();
    new_indices_.reset();
    query_dataset_.reset();

    IdxT n_rows             = h_query_dataset.extent(0);
    IdxT n_neighbors        = h_neighbors.extent(1);
    auto query_dataset_view = store_to_device(handle, query_dataset_, h_query_dataset);
    auto neighbors_view     = neighbors_
                            .emplace(std::move(raft::make_device_matrix<IdxT, IdxT, row_major>(
                              handle, n_rows, n_neighbors)))
                            .view();
    auto distances_view = distances_
                            .emplace(std::move(raft::make_device_matrix<float, IdxT, row_major>(
                              handle, n_rows, n_neighbors)))
                            .view();

    search_impl(handle, search_params, query_dataset_view, neighbors_view, distances_view);

    raft::copy(h_neighbors.data_handle(),
               neighbors_view.data_handle(),
               n_rows * n_neighbors,
               resource::get_cuda_stream(handle));
    raft::copy(h_distances.data_handle(),
               distances_view.data_handle(),
               n_rows * n_neighbors,
               resource::get_cuda_stream(handle));
  }

  // Sharding, results sent to root rank, then merged by it
  void search(raft::resources const& handle,
              const ann::search_params* search_params,
              raft::host_matrix_view<const T, IdxT, row_major> h_query_dataset,
              IdxT n_neighbors,
              int root_rank)
  {
    index_dataset_.reset();
    new_vectors_.reset();
    new_indices_.reset();
    query_dataset_.reset();

    IdxT n_rows             = h_query_dataset.extent(0);
    auto query_dataset_view = store_to_device(handle, query_dataset_, h_query_dataset);
    auto neighbors_view     = neighbors_
                            .emplace(std::move(raft::make_device_matrix<IdxT, IdxT, row_major>(
                              handle, n_rows, n_neighbors)))
                            .view();
    auto distances_view = distances_
                            .emplace(std::move(raft::make_device_matrix<float, IdxT, row_major>(
                              handle, n_rows, n_neighbors)))
                            .view();

    search_impl(handle, search_params, query_dataset_view, neighbors_view, distances_view);

    const auto& comms = resource::get_comms(handle);
    comms.device_send(neighbors_view.data_handle(),
                      n_rows * n_neighbors,
                      root_rank,
                      resource::get_cuda_stream(handle));
    comms.device_send(distances_view.data_handle(),
                      n_rows * n_neighbors,
                      root_rank,
                      resource::get_cuda_stream(handle));
  }

 private:
  template <typename DataT, typename DataIdxT>
  raft::device_matrix_view<const DataT, DataIdxT, row_major> store_to_device(
    raft::resources const& handle,
    std::optional<raft::device_matrix<DataT, DataIdxT, row_major>>& dev_mat_opt,
    raft::host_matrix_view<const DataT, DataIdxT, row_major> host_mat_view)
  {
    DataIdxT n_rows = host_mat_view.extent(0);
    DataIdxT n_cols = host_mat_view.extent(1);
    dev_mat_opt.emplace(
      std::move(raft::make_device_matrix<DataT, DataIdxT, row_major>(handle, n_rows, n_cols)));
    raft::copy(dev_mat_opt.value().data_handle(),  // async copy
               host_mat_view.data_handle(),
               n_rows * n_cols,
               resource::get_cuda_stream(handle));
    auto const_dev_mat_view = dev_mat_opt.value().view();
    raft::device_matrix_view<const DataT, DataIdxT, row_major> dev_mat_view =
      raft::make_device_matrix_view<const DataT, DataIdxT, row_major>(
        const_dev_mat_view.data_handle(),
        const_dev_mat_view.extent(0),
        const_dev_mat_view.extent(1));
    return dev_mat_view;
  }

  template <typename DataT, typename DataIdxT>
  raft::device_vector_view<const DataT, DataIdxT, row_major> store_to_device(
    raft::resources const& handle,
    std::optional<raft::device_vector<DataT, DataIdxT>>& dev_vec_opt,
    raft::host_vector_view<const DataT, DataIdxT> host_vec_view)
  {
    DataIdxT n_rows = host_vec_view.extent(0);
    dev_vec_opt.emplace(std::move(raft::make_device_vector<DataT, DataIdxT>(handle, n_rows)));
    raft::copy(dev_vec_opt.value().data_handle(),  // async copy
               host_vec_view.data_handle(),
               n_rows,
               resource::get_cuda_stream(handle));
    auto const_dev_vec_view = dev_vec_opt.value().view();
    raft::device_vector_view<const DataT, DataIdxT> dev_vec_view =
      raft::make_device_vector_view<const DataT, DataIdxT>(const_dev_vec_view.data_handle(),
                                                           const_dev_vec_view.extent(0));
    return dev_vec_view;
  }

  std::optional<raft::device_matrix<T, IdxT, row_major>> index_dataset_;
  std::optional<raft::device_matrix<T, IdxT, row_major>> new_vectors_;
  std::optional<raft::device_vector<IdxT, IdxT, row_major>> new_indices_;
  std::optional<raft::device_matrix<T, IdxT, row_major>> query_dataset_;
  std::optional<raft::device_matrix<IdxT, IdxT, row_major>> neighbors_;
  std::optional<raft::device_matrix<float, IdxT, row_major>> distances_;
  std::optional<AnnIndexType> index_;
};

template <typename AnnIndexType, typename T, typename IdxT>
class ann_mg_index {
 public:
  ann_mg_index() = delete;
  ann_mg_index(const std::vector<int>& dev_list, dist_mode mode = SHARDING)
    : mode_(mode),
      root_rank_(0),
      num_ranks_(dev_list.size()),
      dev_ids_(dev_list),
      nccl_comms_(dev_list.size())
  {
    RAFT_NCCL_TRY(ncclCommInitAll(nccl_comms_.data(), num_ranks_, dev_ids_.data()));
    for (int rank = 0; rank < num_ranks_; rank++) {
      RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));

      raft::device_resources& handle = dev_resources_.emplace_back();
      raft::comms::build_comms_nccl_only(&handle, nccl_comms_[rank], num_ranks_, rank);
    }
  }

  ~ann_mg_index()
  {
    for (int rank = 0; rank < num_ranks_; rank++) {
      cudaSetDevice(dev_ids_[rank]);
      ncclCommDestroy(nccl_comms_[rank]);
    }
  }

  ann_mg_index(const ann_mg_index&)                    = delete;
  ann_mg_index(ann_mg_index&&)                         = default;
  auto operator=(const ann_mg_index&) -> ann_mg_index& = delete;
  auto operator=(ann_mg_index&&) -> ann_mg_index&      = default;

  void build(const ann::index_params* index_params,
             raft::host_matrix_view<const T, IdxT, row_major> index_dataset)
  {
    if (mode_ == INDEX_DUPLICATION) {
      for (int rank = 0; rank < num_ranks_; rank++) {
        RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));
        auto& ann_if = ann_interfaces_.emplace_back();
        ann_if.build(dev_resources_[rank], index_params, index_dataset);
      }
    } else if (mode_ == SHARDING) {
      IdxT n_rows           = index_dataset.extent(0);
      IdxT n_cols           = index_dataset.extent(1);
      IdxT n_rows_per_shard = (n_rows + num_ranks_ - 1) / num_ranks_;
      IdxT offset           = 0;
      for (int rank = 0; rank < num_ranks_; rank++) {
        RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));
        n_rows_per_shard       = std::min(n_rows_per_shard, n_rows - offset);
        const T* partition_ptr = index_dataset.data_handle() + offset;
        auto partition         = raft::make_host_matrix_view<const T, IdxT, row_major>(
          partition_ptr, n_rows_per_shard, n_cols);
        auto& ann_if = ann_interfaces_.emplace_back();
        ann_if.build(dev_resources_[rank], index_params, partition);
        offset += n_rows_per_shard * n_cols;
      }
    }
    set_current_device_to_root_rank();
  }

  void extend(raft::host_matrix_view<const T, IdxT, row_major> new_vectors,
              std::optional<raft::host_vector_view<const IdxT, IdxT>> new_indices)
  {
    if (mode_ == INDEX_DUPLICATION) {
      for (int rank = 0; rank < num_ranks_; rank++) {
        RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));
        auto& ann_if = ann_interfaces_[rank];
        ann_if.extend(dev_resources_[rank], new_vectors, new_indices);
      }
    } else if (mode_ == SHARDING) {
      IdxT n_rows           = new_vectors.extent(0);
      IdxT n_cols           = new_vectors.extent(1);
      IdxT n_rows_per_shard = (n_rows + num_ranks_ - 1) / num_ranks_;
      IdxT offset           = 0;
      for (int rank = 0; rank < num_ranks_; rank++) {
        RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));
        n_rows_per_shard         = std::min(n_rows_per_shard, n_rows - offset);
        const T* new_vectors_ptr = new_vectors.data_handle() + offset;
        auto new_vectors_part    = raft::make_host_matrix_view<const T, IdxT, row_major>(
          new_vectors_ptr, n_rows_per_shard, n_cols);

        std::optional<raft::host_vector_view<const IdxT, IdxT>> new_indices_part = std::nullopt;
        if (new_indices) {
          const IdxT* new_indices_ptr = new_indices.value().data_handle() + offset;
          new_indices_part =
            raft::make_host_vector_view<const IdxT, IdxT>(new_indices_ptr, n_rows_per_shard);
        }
        auto& ann_if = ann_interfaces_[rank];
        ann_if.extend(dev_resources_[rank], new_vectors_part, new_indices_part);
        offset += n_rows_per_shard * n_cols;
      }
    }
    set_current_device_to_root_rank();
  }

  void search(const ann::search_params* search_params,
              raft::host_matrix_view<const T, IdxT, row_major> query_dataset,
              raft::host_matrix_view<IdxT, IdxT, row_major> neighbors,
              raft::host_matrix_view<float, IdxT, row_major> distances)
  {
    if (mode_ == INDEX_DUPLICATION) {
      IdxT n_rows           = query_dataset.extent(0);
      IdxT n_cols           = query_dataset.extent(1);
      IdxT n_neighbors      = neighbors.extent(1);
      IdxT n_rows_per_shard = (n_rows + num_ranks_ - 1) / num_ranks_;
      IdxT query_offset     = 0;
      IdxT output_offset    = 0;
      for (int rank = 0; rank < num_ranks_; rank++) {
        RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));
        n_rows_per_shard     = std::min(n_rows_per_shard, n_rows - query_offset);
        auto query_partition = raft::make_host_matrix_view<const T, IdxT, row_major>(
          query_dataset.data_handle() + query_offset, n_rows_per_shard, n_cols);
        auto neighbors_partition = raft::make_host_matrix_view<IdxT, IdxT, row_major>(
          neighbors.data_handle() + output_offset, n_rows_per_shard, n_neighbors);
        auto distances_partition = raft::make_host_matrix_view<float, IdxT, row_major>(
          distances.data_handle() + output_offset, n_rows_per_shard, n_neighbors);
        auto& ann_if = ann_interfaces_[rank];
        ann_if.search(dev_resources_[rank],
                      search_params,
                      query_partition,
                      neighbors_partition,
                      distances_partition);
        query_offset += n_rows_per_shard * n_cols;
        output_offset += n_rows_per_shard * n_neighbors;
      }
    } else if (mode_ == SHARDING) {
      IdxT n_rows      = query_dataset.extent(0);
      IdxT n_cols      = query_dataset.extent(1);
      IdxT n_neighbors = neighbors.extent(1);

      IdxT n_rows_per_batches = N_ROWS_PER_BATCH;
      IdxT n_batches          = (n_rows + n_rows_per_batches - 1) / n_rows_per_batches;

      const auto& root_handle = set_current_device_to_root_rank();
      auto in_neighbors       = raft::make_device_matrix<IdxT, IdxT, row_major>(
        root_handle, num_ranks_ * n_rows_per_batches, n_neighbors);
      auto in_distances = raft::make_device_matrix<float, IdxT, row_major>(
        root_handle, num_ranks_ * n_rows_per_batches, n_neighbors);
      auto out_neighbors = raft::make_device_matrix<IdxT, IdxT, row_major>(
        root_handle, n_rows_per_batches, n_neighbors);
      auto out_distances = raft::make_device_matrix<float, IdxT, row_major>(
        root_handle, n_rows_per_batches, n_neighbors);

      IdxT query_offset  = 0;
      IdxT output_offset = 0;
      for (IdxT batch_idx = 0; batch_idx < n_batches; batch_idx++) {
        n_rows_per_batches   = std::min(n_rows_per_batches, n_rows - query_offset);
        auto query_partition = raft::make_host_matrix_view<const T, IdxT, row_major>(
          query_dataset.data_handle() + query_offset, n_rows_per_batches, n_cols);

        RAFT_NCCL_TRY(ncclGroupStart());
        for (int rank = 0; rank < num_ranks_; rank++) {
          RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[rank]));
          auto& ann_if = ann_interfaces_[rank];
          ann_if.search(
            dev_resources_[rank], search_params, query_partition, n_neighbors, root_rank_);

          const auto& root_handle = set_current_device_to_root_rank();
          const auto& comms       = resource::get_comms(root_handle);
          uint64_t batch_offset   = rank * n_rows_per_batches * n_neighbors;
          comms.device_recv(in_neighbors.data_handle() + batch_offset,
                            n_rows_per_batches * n_neighbors,
                            rank,
                            resource::get_cuda_stream(root_handle));
          comms.device_recv(in_distances.data_handle() + batch_offset,
                            n_rows_per_batches * n_neighbors,
                            rank,
                            resource::get_cuda_stream(root_handle));
        }
        RAFT_NCCL_TRY(ncclGroupEnd());

        auto in_neighbors_view  = raft::make_device_matrix_view<const IdxT, IdxT, row_major>(
          in_neighbors.data_handle(), num_ranks_ * n_rows_per_batches, n_neighbors);
        auto in_distances_view = raft::make_device_matrix_view<const float, IdxT, row_major>(
          in_distances.data_handle(), num_ranks_ * n_rows_per_batches, n_neighbors);
        auto out_neighbors_view = raft::make_device_matrix_view<IdxT, IdxT, row_major>(
          out_neighbors.data_handle(), n_rows_per_batches, n_neighbors);
        auto out_distances_view = raft::make_device_matrix_view<float, IdxT, row_major>(
          out_distances.data_handle(), n_rows_per_batches, n_neighbors);

        const auto& root_handle_ = set_current_device_to_root_rank();
        auto trans = raft::make_device_vector<IdxT, IdxT>(root_handle_, num_ranks_);
        RAFT_CUDA_TRY(cudaMemsetAsync(trans.data_handle(), 0, num_ranks_ * sizeof(IdxT), resource::get_cuda_stream(root_handle_)));
        auto translations = std::make_optional<raft::device_vector_view<IdxT, IdxT>>(trans.view());
        raft::neighbors::brute_force::knn_merge_parts<float, IdxT>(root_handle_,
                                                                   in_distances_view,
                                                                   in_neighbors_view,
                                                                   out_distances_view,
                                                                   out_neighbors_view,
                                                                   n_rows_per_batches,
                                                                   translations);

        raft::copy(neighbors.data_handle() + output_offset,
                   out_neighbors.data_handle(),
                   n_rows_per_batches * n_neighbors,
                   resource::get_cuda_stream(root_handle_));
        raft::copy(distances.data_handle() + output_offset,
                   out_distances.data_handle(),
                   n_rows_per_batches * n_neighbors,
                   resource::get_cuda_stream(root_handle_));

        query_offset += n_rows_per_batches * n_cols;
        output_offset += n_rows_per_batches * n_neighbors;
      }
    }

    set_current_device_to_root_rank();
  }

  inline const raft::device_resources& set_current_device_to_root_rank()
  {
    RAFT_CUDA_TRY(cudaSetDevice(dev_ids_[root_rank_]));
    return dev_resources_[root_rank_];
  }

 private:
  dist_mode mode_;
  int root_rank_;
  int num_ranks_;
  std::vector<int> dev_ids_;
  std::vector<raft::device_resources> dev_resources_;
  std::vector<ann_interface<AnnIndexType, T, IdxT>> ann_interfaces_;
  std::vector<ncclComm_t> nccl_comms_;
};

template <typename T, typename IdxT>
ann_mg_index<ivf_flat::index<T, IdxT>, T, IdxT> build(
  const std::vector<int> device_ids,
  dist_mode mode,
  const ivf_flat::index_params& index_params,
  raft::host_matrix_view<const T, IdxT, row_major> index_dataset)
{
  ann_mg_index<ivf_flat::index<T, IdxT>, T, IdxT> index(device_ids, mode);
  index.build(static_cast<const ann::index_params*>(&index_params), index_dataset);
  return index;
}

template <typename T>
ann_mg_index<ivf_pq::index<uint32_t>, T, uint32_t> build(
  const std::vector<int> device_ids,
  dist_mode mode,
  const ivf_pq::index_params& index_params,
  raft::host_matrix_view<const T, uint32_t, row_major> index_dataset)
{
  ann_mg_index<ivf_pq::index<uint32_t>, T, uint32_t> index(device_ids, mode);
  index.build(static_cast<const ann::index_params*>(&index_params), index_dataset);
  return index;
}

template <typename T, typename IdxT>
void extend(ann_mg_index<ivf_flat::index<T, IdxT>, T, IdxT>& index,
            raft::host_matrix_view<const T, IdxT, row_major> new_vectors,
            std::optional<raft::host_vector_view<const IdxT, IdxT>> new_indices)
{
  index.extend(new_vectors, new_indices);
}

template <typename T>
void extend(ann_mg_index<ivf_pq::index<uint32_t>, T, uint32_t>& index,
            raft::host_matrix_view<const T, uint32_t, row_major> new_vectors,
            std::optional<raft::host_vector_view<const uint32_t, uint32_t>> new_indices)
{
  index.extend(new_vectors, new_indices);
}

template <typename T, typename IdxT>
void search(ann_mg_index<ivf_flat::index<T, IdxT>, T, IdxT>& index,
            const ivf_flat::search_params& search_params,
            raft::host_matrix_view<const T, IdxT, row_major> query_dataset,
            raft::host_matrix_view<IdxT, IdxT, row_major> neighbors,
            raft::host_matrix_view<float, IdxT, row_major> distances)
{
  index.search(
    static_cast<const ann::search_params*>(&search_params), query_dataset, neighbors, distances);
}

template <typename T>
void search(ann_mg_index<ivf_pq::index<uint32_t>, T, uint32_t>& index,
            const ivf_pq::search_params& search_params,
            raft::host_matrix_view<const T, uint32_t, row_major> query_dataset,
            raft::host_matrix_view<uint32_t, uint32_t, row_major> neighbors,
            raft::host_matrix_view<float, uint32_t, row_major> distances)
{
  index.search(
    static_cast<const ann::search_params*>(&search_params), query_dataset, neighbors, distances);
}

}  // namespace raft::neighbors::mg::detail