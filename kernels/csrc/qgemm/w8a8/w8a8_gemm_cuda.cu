// Implemented by Haotian Tang and Shang Yang.
// @article{lin2024qserve,
//   title={QServe: W4A8KV4 Quantization and System Co-design for Efficient LLM Serving},
//   author={Lin*, Yujun and Tang*, Haotian and Yang*, Shang and Zhang, Zhekai and Xiao, Guangxuan and Gan, Chuang and Han, Song},
//   journal={arXiv preprint arXiv:2405.04532},
//   year={2024}
// }

#include "w8a8_gemm_cuda.h"
#include <cuda_fp16.h>
#include <cuda_pipeline_primitives.h>
#include <torch/extension.h>

#define OP_M 16
#define OP_N 8
#define OP_K 32
#define INTRIN_M 16
#define INTRIN_N 16
#define INTRIN_K 32
#define WARP_SIZE 32
#define SMEM_PAD_A 0
#define SMEM_PAD_B 0
#define PACK_SIZE 16
#if (__CUDACC_VER_MAJOR__ >= 11) && (__CUDACC_VER_MINOR__ >= 4)
#define L2_CACHEHINT(size) ".L2::" #size "B"
#else
#define L2_CACHEHINT(size)
#endif
#define KERNEL_LAUNCH_CODE                                                       \
  constexpr int NUM_WARPS = (CTA_M / WARP_M) * (CTA_N / WARP_N) * (CTA_K / WARP_K); \
  constexpr int kSmemByteSize =                                                  \
      (CTA_M * (CTA_K + SMEM_PAD_A) + CTA_N * (CTA_K + SMEM_PAD_B)) * STAGES *   \
      sizeof(int8_t);                                                            \
  if (kSmemByteSize >= 99 * 1024)                                                \
  {                                                                              \
    printf("This kernel requires %d Bytes of shared memory, which exceeds "      \
           "device limit.\n",                                                    \
           kSmemByteSize);                                                       \
    return _out_feats;                                                           \
  }                                                                              \
  int num_blocks_m = (num_out_feats + CTA_M - 1) / CTA_M;                        \
  int num_blocks_n = num_out_channels / CTA_N / 1;                               \
  const int log_tile = get_log_tile<8>((num_out_feats + CTA_M - 1) / CTA_M);     \
  const int tile_shift = 1 << log_tile;                                          \
  dim3 num_blocks(num_blocks_n *tile_shift,                                      \
                  (num_blocks_m + tile_shift - 1) / tile_shift);                 \
  dim3 threads_per_block(WARP_SIZE, NUM_WARPS);                                  \
  auto kernel_func =                                                             \
      dense_kernel0<CTA_M, CTA_N, CTA_K, WARP_M, WARP_N, WARP_K, STAGES>;        \
  cudaFuncSetAttribute(kernel_func, cudaFuncAttributeMaxDynamicSharedMemorySize, \
                       kSmemByteSize);                                           \
  kernel_func<<<num_blocks, threads_per_block, kSmemByteSize>>>(                 \
      in_feats, kernel, wscales, ascales, out_feats, num_in_feats, num_out_channels,               \
      num_in_channels);

template <int N>
__inline__ __host__ __device__ int get_log_tile(int n)
{
  if (N >= 8 && n >= 6)
    return 3;
  else if (N >= 4 && n >= 3)
    return 2;
  else if (N >= 2 && n >= 2)
    return 1;
  else
    return 0;
}

__inline__ __device__ uint2 get_block_idx_mapping(int blockIdx_x,
                                                  int blockIdx_y,
                                                  int log_tile)
{
  return make_uint2((blockIdx_x >> log_tile),
                    (blockIdx_y << log_tile) +
                        ((blockIdx_x) & ((1 << (log_tile)) - 1)));
}

__inline__ __device__ uint32_t cast_smem_ptr_to_uint(void const *const ptr)
{
  uint32_t smem_int_ptr;

  asm("{.reg .u64 smem_ptr; cvta.to.shared.u64 smem_ptr, %1; cvt.u32.u64 %0, "
      "smem_ptr; }\n"
      : "=r"(smem_int_ptr)
      : "l"(ptr));

  return smem_int_ptr;
}

__inline__ __device__ void ldmatrix_m8n8_x4_b16(int8_t *shared_warp, int ax0_0,
                                                uint32_t addr)
{
  __asm__ __volatile__("ldmatrix.sync.aligned.m8n8.x4.shared.b16"
                       "{%0, %1, %2, %3}, [%4];"
                       : "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[0]),
                         "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[1]),
                         "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[2]),
                         "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[3])
                       : "r"(addr));
}

__inline__ __device__ void
ldmatrix_m8n8_x4_trans_b16(int8_t *shared_warp, int ax0_0, uint32_t addr)
{
  __asm__ __volatile__("ldmatrix.sync.aligned.m8n8.x4.trans.shared.b16"
                       "{%0, %1, %2, %3}, [%4];"
                       : "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[0]),
                         "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[1]),
                         "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[2]),
                         "=r"(((unsigned *)(shared_warp + (ax0_0 * 16)))[3])
                       : "r"(addr));
}

// function from lmdeploy
__inline__ __device__ void
cp_async_cg_A(uint32_t smem_int_ptr, const uint4 *__restrict__ src, bool mask)
{
  const int cp_size = 16;
  asm volatile("{"
                "  .reg .pred p;"
                "  setp.ne.b32 p, %0, 0;"
                "  @p cp.async.cg.shared.global" L2_CACHEHINT(128) " [%1], [%2], %3;"
                "}" ::"r"((int)mask),
                "r"(smem_int_ptr),
                "l"(src),
                "n"(cp_size));
}

__device__ __inline__ void mma_m16n8k32(void *C_warp, void *A_shared_warp,
                                        void *B_shared_warp)
{
  __asm__ __volatile__(
      "mma.sync.aligned.m16n8k32.row.col.s32.s8.s8.s32"
      "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%10, %11, %12, %13};"
      : "=r"(((int *)C_warp)[0]), "=r"(((int *)C_warp)[1]),
        "=r"(((int *)C_warp)[2]), "=r"(((int *)C_warp)[3])
      : "r"(((unsigned *)A_shared_warp)[0]),
        "r"(((unsigned *)A_shared_warp)[1]),
        "r"(((unsigned *)A_shared_warp)[2]),
        "r"(((unsigned *)A_shared_warp)[3]),
        "r"(((unsigned *)B_shared_warp)[0]),
        "r"(((unsigned *)B_shared_warp)[1]), "r"(((int *)C_warp)[0]),
        "r"(((int *)C_warp)[1]), "r"(((int *)C_warp)[2]),
        "r"(((int *)C_warp)[3]));
}

template <int CTA_M, int CTA_N, int CTA_K, int CTA_SIZE, int SHARED_K_ITERS,
          int STAGES>
__device__ __inline__ void
global_to_share_one_stage_A(int8_t *src, int8_t *dst, int global_ncols,
                            int cta_offset_m, int cta_offset_n,
                            int global_iter_k, int shared_iter_k, bool mask,
                            bool *preds)
{
  constexpr int total_global_iters = (CTA_M * CTA_K) / PACK_SIZE / CTA_SIZE;
  constexpr int partial_global_iters = total_global_iters / SHARED_K_ITERS;
  constexpr int cta_step_m_or_n = (CTA_SIZE * PACK_SIZE) / CTA_K;
  constexpr int warp_step_m_or_n = (WARP_SIZE * PACK_SIZE) / CTA_K;
  constexpr int threads_per_row = CTA_K / PACK_SIZE;
  constexpr int kSmemCol = CTA_K + SMEM_PAD_A;
  int8_t *dst_hoisted = dst;
  int8_t *src_hoisted = src + global_iter_k * CTA_K;

  if (mask)
  {
#pragma unroll
    for (int _global_iter = 0; _global_iter < partial_global_iters;
         ++_global_iter)
    {
      int global_iter = shared_iter_k * partial_global_iters + _global_iter;

      void *dst_ptr =
          (void *)(dst_hoisted + global_iter * cta_step_m_or_n * kSmemCol);
      uint4 *src_ptr =
          (uint4 *)(src_hoisted + global_iter * cta_step_m_or_n * global_ncols);
      if constexpr (STAGES > 1)
      {
        uint32_t addr = cast_smem_ptr_to_uint(dst_ptr);
        cp_async_cg_A(addr, src_ptr, preds[global_iter]);
      }
      else
      {
        if (preds[global_iter])
          *(uint4 *)dst_ptr = *src_ptr;
      }
    }
  }
}

template <int CTA_M, int CTA_N, int CTA_K, int CTA_SIZE, int SHARED_K_ITERS,
          int STAGES>
__device__ __inline__ void
global_to_share_one_stage_B(int8_t *src, int8_t *dst, int global_ncols,
                            int cta_offset_m, int cta_offset_n,
                            int global_iter_k, int shared_iter_k, bool mask)
{
  constexpr int total_global_iters = (CTA_N * CTA_K) / PACK_SIZE / CTA_SIZE;
  constexpr int partial_global_iters = total_global_iters / SHARED_K_ITERS;
  constexpr int cta_step_m_or_n = (CTA_SIZE * PACK_SIZE) / CTA_K;
  constexpr int warp_step_m_or_n = (WARP_SIZE * PACK_SIZE) / CTA_K;
  constexpr int threads_per_row = CTA_K / PACK_SIZE;
  constexpr int kSmemCol = CTA_K + SMEM_PAD_B;
  int8_t *dst_hoisted = dst;
  int8_t *src_hoisted = src + global_iter_k * CTA_K;

#pragma unroll
  for (int _global_iter = 0; _global_iter < partial_global_iters;
       ++_global_iter)
  {
    int global_iter = shared_iter_k * partial_global_iters + _global_iter;

    void *dst_ptr =
        (void *)(dst_hoisted + global_iter * cta_step_m_or_n * kSmemCol);
    uint4 *src_ptr =
        (uint4 *)(src_hoisted + global_iter * cta_step_m_or_n * global_ncols);
    if constexpr (STAGES > 1)
    {
      uint32_t addr = cast_smem_ptr_to_uint(dst_ptr);
      cp_async_cg_A(addr, src_ptr, mask);
    }
    else
    {
      if (mask)
        *(uint4 *)dst_ptr = *src_ptr;
    }
  }
}

template <int CTA_M, int CTA_N, int CTA_K, int CTA_SIZE, int STAGES>
__device__ __inline__ void
share_to_reg_one_stage_A(int8_t *src, int8_t *dst, int warp_offset_m,
                         int warp_offset_n, int k_0_1, int shared_iters)
{
  constexpr int kSmemCol = CTA_K + SMEM_PAD_A;
  int ld_col = (k_0_1 * INTRIN_K + (threadIdx.x / 16) * 16) / PACK_SIZE;

  for (int shared_iter = 0; shared_iter < shared_iters; ++shared_iter)
  {
    int ld_row = warp_offset_m + shared_iter * INTRIN_M + (threadIdx.x % 16);
    int ld_col_swizzled = ld_col ^ (ld_row / 2) & 3;
    void *addr_ptr =
        (void *)(src + ld_row * kSmemCol + ld_col_swizzled * PACK_SIZE);
    uint32_t addr = cast_smem_ptr_to_uint(addr_ptr);
    ldmatrix_m8n8_x4_b16(dst, shared_iter, addr);
  }
}

template <int CTA_M, int CTA_N, int CTA_K, int CTA_SIZE, int STAGES>
__device__ __inline__ void
share_to_reg_one_stage_B(int8_t *src, int8_t *dst, int warp_offset_m,
                         int warp_offset_n, int k_0_1, int shared_iters)
{
  constexpr int kSmemCol = CTA_K + SMEM_PAD_B;
  int ld_col = (k_0_1 * INTRIN_K + ((threadIdx.x / 8) % 2) * 16) / PACK_SIZE;

  for (int shared_iter = 0; shared_iter < shared_iters; ++shared_iter)
  {
    int ld_row = warp_offset_n + shared_iter * INTRIN_N + ((threadIdx.x / 8 / 2) * 8 + threadIdx.x % 8);
    int ld_col_swizzled = ld_col ^ (ld_row / 2) & 3;
    void *addr_ptr =
        (void *)(src + ld_row * kSmemCol + ld_col_swizzled * PACK_SIZE);
    uint32_t addr = cast_smem_ptr_to_uint(addr_ptr);
    ldmatrix_m8n8_x4_b16(dst, shared_iter, addr);
  }
}

template <int CTA_M, int CTA_N, int CTA_K, int WARP_M, int WARP_N, int WARP_K,
          int STAGES>
__global__ void dense_kernel0(int8_t *__restrict__ A, int8_t *__restrict__ B,
                              half2 *__restrict__ wscales, half *__restrict__ ascales,
                              half *__restrict__ C, int M, int N, int K)
{
  constexpr int NUM_WARPS_MN = CTA_M / WARP_M * CTA_N / WARP_N;
  constexpr int NUM_WARPS = NUM_WARPS_MN * CTA_K / WARP_K;
  constexpr int CTA_SIZE = NUM_WARPS * WARP_SIZE;
  constexpr int CTA_SIZE_MN = NUM_WARPS_MN * WARP_SIZE;
  constexpr int SLICES = CTA_K / WARP_K;
  int num_blocks_n = (N + CTA_N - 1) / CTA_N;
  int num_blocks_m = (M + CTA_M - 1) / CTA_M;

  int blockIdx_n = blockIdx.x;
  int blockIdx_m = blockIdx.y;
  const int log_tile = get_log_tile<8>((M + CTA_M - 1) / CTA_M);
  const uint2 block_idx_mapping =
      get_block_idx_mapping(blockIdx_n, blockIdx_m, log_tile);
  blockIdx_n = block_idx_mapping.x;
  blockIdx_m = block_idx_mapping.y;

  int C_warp[CTA_M * CTA_N / CTA_SIZE_MN];
  constexpr int kSmemPadKA = CTA_K + SMEM_PAD_A;
  constexpr int kSmemPadKB = CTA_K + SMEM_PAD_B;
  constexpr int kSmemSizeAPerStage = CTA_M * kSmemPadKA;
  constexpr int kSmemSizeBPerStage = CTA_N * kSmemPadKB;
  constexpr int kSmemSizeA = kSmemSizeAPerStage * STAGES;
  constexpr int kSmemSizeB = kSmemSizeBPerStage * STAGES;
  extern __shared__ int8_t mem_shared[];
  int8_t *A_shared = mem_shared;
  int8_t *B_shared = mem_shared + kSmemSizeA;
  int8_t A_shared_warp_[2][WARP_M * WARP_K /
                           WARP_SIZE];
  int8_t B_shared_warp_[2][WARP_N * WARP_K /
                           WARP_SIZE];
  constexpr int A_total_global_iters = (CTA_M * CTA_K) / PACK_SIZE / CTA_SIZE;
  constexpr int B_total_global_iters = (CTA_N * CTA_K) / PACK_SIZE / CTA_SIZE;
  constexpr int A_src_step_m = (CTA_SIZE * PACK_SIZE) / CTA_K;
  constexpr int B_src_step_k = (CTA_SIZE * PACK_SIZE) / CTA_K;
  constexpr int A_warp_step_m = (WARP_SIZE * PACK_SIZE) / CTA_K;
  constexpr int B_warp_step_n = (WARP_SIZE * PACK_SIZE) / CTA_K;
  constexpr int A_threads_per_row = CTA_K / PACK_SIZE;
  constexpr int B_threads_per_row = CTA_K / PACK_SIZE;
  int cta_offset_m = blockIdx_m * CTA_M;
  int cta_offset_n = blockIdx_n * CTA_N;
  int warp_mn = threadIdx.y % NUM_WARPS_MN;
  int slice_id = threadIdx.y / NUM_WARPS_MN;
  int warp_offset_m = (warp_mn % (CTA_M / WARP_M)) * WARP_M;
  int warp_offset_n = (warp_mn / (CTA_M / WARP_M)) * WARP_N;
  int warp_offset_k = slice_id * WARP_K;

  for (int i = 0; i < CTA_M * CTA_N / CTA_SIZE_MN; i++)
    C_warp[i] = 0;

  int gemm_iters = (K + CTA_K - 1) / CTA_K;
  int k_0_0_ld = 0;
  int k_0_0 = 0;
  constexpr int prologue_stages = STAGES == 1 ? 1 : STAGES - 1;
  int A_hoisted_row = threadIdx.y * A_warp_step_m + (threadIdx.x / A_threads_per_row);
  int A_hoisted_col = (threadIdx.x % A_threads_per_row);
  int A_hoisted_col_swizzled = A_hoisted_col ^ (A_hoisted_row / 2) & 3;

  int B_hoisted_row = threadIdx.y * B_warp_step_n + (threadIdx.x / B_threads_per_row);
  int B_hoisted_col = (threadIdx.x % B_threads_per_row);
  int B_hoisted_col_swizzled = B_hoisted_col ^ (B_hoisted_row / 2) & 3;

  int8_t *A_shared_hoisted = A_shared +
                             A_hoisted_row * kSmemPadKA +
                             A_hoisted_col_swizzled * PACK_SIZE;
  int8_t *B_shared_hoisted = B_shared + B_hoisted_row * kSmemPadKB +
                             B_hoisted_col_swizzled * PACK_SIZE;
  int8_t *A_hoisted = A + cta_offset_m * K + A_hoisted_row * K +
                      A_hoisted_col * PACK_SIZE;
  int8_t *B_hoisted = B + cta_offset_n * K + B_hoisted_row * K +
                      B_hoisted_col * PACK_SIZE;
  bool A_g2s_preds[A_total_global_iters];
#pragma unroll
  for (int i = 0; i < A_total_global_iters; i++)
  {
    A_g2s_preds[i] = (cta_offset_m + A_hoisted_row + i * A_src_step_m) < M;
  }
  int *C_shared = reinterpret_cast<int *>(mem_shared);
#pragma unroll
  for (k_0_0_ld = 0; k_0_0_ld < prologue_stages; ++k_0_0_ld)
  {
    global_to_share_one_stage_A<CTA_M, CTA_N, CTA_K, CTA_SIZE, 1, STAGES>(
        A_hoisted, A_shared_hoisted + k_0_0_ld * kSmemSizeAPerStage, K,
        cta_offset_m, cta_offset_n, k_0_0_ld, 0, true, A_g2s_preds);
    global_to_share_one_stage_B<CTA_M, CTA_N, CTA_K, CTA_SIZE, 1, STAGES>(
        B_hoisted, B_shared_hoisted + k_0_0_ld * kSmemSizeBPerStage, K,
        cta_offset_m, cta_offset_n, k_0_0_ld, 0, true);
    if constexpr (STAGES > 1)
      __pipeline_commit();
  }
  if constexpr (STAGES > 1)
    __pipeline_wait_prior(STAGES - 2);
  __syncthreads();

  share_to_reg_one_stage_A<CTA_M, CTA_N, CTA_K, CTA_SIZE, STAGES>(
      A_shared + warp_offset_k, A_shared_warp_[0], warp_offset_m, warp_offset_n, 0,
      WARP_M / INTRIN_M);
  share_to_reg_one_stage_B<CTA_M, CTA_N, CTA_K, CTA_SIZE, STAGES>(
      B_shared + warp_offset_k, B_shared_warp_[0], warp_offset_m, warp_offset_n, 0,
      WARP_N / INTRIN_N);
  constexpr int SHARED_K_ITERS = WARP_K / INTRIN_K;

  for (; k_0_0 < gemm_iters; ++k_0_0, ++k_0_0_ld)
  {
    int ld_stage = k_0_0_ld % STAGES;
    int compute_stage = k_0_0 % STAGES;
    int8_t *A_shared_this_compute_stage;
    int8_t *B_shared_this_compute_stage;

    for (int iter_k = 0; iter_k < SHARED_K_ITERS; ++iter_k)
    {
      A_shared_this_compute_stage =
          A_shared + compute_stage * kSmemSizeAPerStage + warp_offset_k;
      B_shared_this_compute_stage =
          B_shared + compute_stage * kSmemSizeBPerStage + warp_offset_k;
      share_to_reg_one_stage_A<CTA_M, CTA_N, CTA_K, CTA_SIZE, STAGES>(
          A_shared_this_compute_stage, A_shared_warp_[(iter_k + 1) % 2],
          warp_offset_m, warp_offset_n, (iter_k + 1) % SHARED_K_ITERS,
          WARP_M / INTRIN_M);
      share_to_reg_one_stage_B<CTA_M, CTA_N, CTA_K, CTA_SIZE, STAGES>(
          B_shared_this_compute_stage, B_shared_warp_[(iter_k + 1) % 2],
          warp_offset_m, warp_offset_n, (iter_k + 1) % SHARED_K_ITERS,
          WARP_N / INTRIN_N);
      int8_t *A_shared_warp = A_shared_warp_[iter_k % 2];
      int8_t *B_shared_warp = B_shared_warp_[iter_k % 2];
      for (int i_0_3 = 0; i_0_3 < WARP_M / INTRIN_M; ++i_0_3)
      {
        for (int j_0_4 = 0; j_0_4 < WARP_N / INTRIN_N; ++j_0_4)
        {
          mma_m16n8k32(
              (void *)(C_warp + i_0_3 * WARP_N / INTRIN_N * 8 + j_0_4 * 8),
              (void *)(A_shared_warp + i_0_3 * 16),
              (void *)(B_shared_warp + j_0_4 * 16));
          mma_m16n8k32(
              (void *)(C_warp + i_0_3 * WARP_N / INTRIN_N * 8 + j_0_4 * 8 + 4),
              (void *)(A_shared_warp + i_0_3 * 16),
              (void *)(B_shared_warp + j_0_4 * 16 + 8));
        }
      }

      if (iter_k < SHARED_K_ITERS - 1)
      {
        if constexpr (STAGES == 1)
          __syncthreads();
        global_to_share_one_stage_A<CTA_M, CTA_N, CTA_K, CTA_SIZE,
                                    WARP_K / INTRIN_K, STAGES>(
            A_hoisted, A_shared_hoisted + ld_stage * kSmemSizeAPerStage, K,
            cta_offset_m, cta_offset_n, k_0_0_ld, iter_k,
            k_0_0_ld < gemm_iters, A_g2s_preds);
        global_to_share_one_stage_B<CTA_M, CTA_N, CTA_K, CTA_SIZE,
                                    WARP_K / INTRIN_K, STAGES>(
            B_hoisted, B_shared_hoisted + ld_stage * kSmemSizeBPerStage, K,
            cta_offset_m, cta_offset_n, k_0_0_ld, iter_k,
            k_0_0_ld < gemm_iters);
      }

      if (iter_k == SHARED_K_ITERS - 2)
      {
        if constexpr (STAGES == 1 && SHARED_K_ITERS > 2)
        {
          __syncthreads();
        }
        global_to_share_one_stage_A<CTA_M, CTA_N, CTA_K, CTA_SIZE,
                                    WARP_K / INTRIN_K, STAGES>(
            A_hoisted, A_shared_hoisted + ld_stage * kSmemSizeAPerStage, K,
            cta_offset_m, cta_offset_n, k_0_0_ld, iter_k + 1,
            k_0_0_ld < gemm_iters, A_g2s_preds);
        global_to_share_one_stage_B<CTA_M, CTA_N, CTA_K, CTA_SIZE,
                                    WARP_K / INTRIN_K, STAGES>(
            B_hoisted, B_shared_hoisted + ld_stage * kSmemSizeBPerStage, K,
            cta_offset_m, cta_offset_n, k_0_0_ld, iter_k + 1,
            k_0_0_ld < gemm_iters);
        if constexpr (STAGES > 1)
        {
          __pipeline_commit();
          __pipeline_wait_prior(STAGES - 2);
        }
        compute_stage = (k_0_0 + 1) % STAGES;
        __syncthreads();
      }
    }
  }
  __pipeline_commit();
  __pipeline_wait_prior(0);
  __syncthreads();

  if constexpr (SLICES > 1)
  {
#pragma unroll
    for (int z = 0; z < SLICES; ++z)
    {
      if (slice_id == z)
      {
#pragma unroll
        for (int ax0_0_1 = 0; ax0_0_1 < WARP_M / INTRIN_M; ++ax0_0_1)
        {
#pragma unroll
          for (int ax1_0_1 = 0; ax1_0_1 < WARP_N / INTRIN_N; ++ax1_0_1)
          {
#pragma unroll
            for (int local_id = 0; local_id < OP_M * 16 / WARP_SIZE; ++local_id)
            {
              if (z > 0)
              {
                C_warp[ax0_0_1 * WARP_N / INTRIN_N * 8 + ax1_0_1 * 8 + local_id] += C_shared[warp_offset_m * CTA_N + ax0_0_1 * OP_M * CTA_N + warp_offset_n + ax1_0_1 * 16 + ((local_id % 4) / 2 * 8 + (threadIdx.x / 4)) * CTA_N + (local_id / 4) * 8 + (local_id % 2) + (threadIdx.x % 4) * 2];
              }
              C_shared[warp_offset_m * CTA_N + ax0_0_1 * OP_M * CTA_N + warp_offset_n + ax1_0_1 * 16 + ((local_id % 4) / 2 * 8 + (threadIdx.x / 4)) * CTA_N + (local_id / 4) * 8 + (local_id % 2) + (threadIdx.x % 4) * 2] = C_warp[ax0_0_1 * WARP_N / INTRIN_N * 8 + ax1_0_1 * 8 + local_id];
            };
          }
        }
      }
      __syncthreads();
    }
    if (slice_id == 0)
    {
#pragma unroll
      for (int ax0_0_1 = 0; ax0_0_1 < WARP_M / INTRIN_M; ++ax0_0_1)
      {
#pragma unroll
        for (int ax1_0_1 = 0; ax1_0_1 < WARP_N / INTRIN_N; ++ax1_0_1)
        {
#pragma unroll
          for (int local_id = 0; local_id < OP_M * 16 / WARP_SIZE; ++local_id)
          {
            C_warp[ax0_0_1 * WARP_N / INTRIN_N * 8 + ax1_0_1 * 8 + local_id] = C_shared[warp_offset_m * CTA_N + ax0_0_1 * OP_M * CTA_N + warp_offset_n + ax1_0_1 * 16 + ((local_id % 4) / 2 * 8 + (threadIdx.x / 4)) * CTA_N + (local_id / 4) * 8 + (local_id % 2) + (threadIdx.x % 4) * 2];
          };
        }
      }
    }
  }

  int row_wb_thd = cta_offset_m + warp_offset_m + (threadIdx.x / 4);
  int col_wb_thd = cta_offset_n + warp_offset_n + (threadIdx.x % 4) * 2;
  if (slice_id == 0)
  {
    for (int ax0_0_1 = 0; ax0_0_1 < WARP_M / INTRIN_M; ++ax0_0_1)
    {
      int row_wb_1 = row_wb_thd + ax0_0_1 * OP_M;
      for (int ax1_0_1 = 0; ax1_0_1 < WARP_N / INTRIN_N; ++ax1_0_1)
      {
        int col_wb_1 = col_wb_thd + ax1_0_1 * 16;
        int *C_warp_local = C_warp + ax0_0_1 * WARP_N / INTRIN_N * 8 + ax1_0_1 * 8;
        for (int local_id = 0; local_id < OP_M * 16 / WARP_SIZE; local_id += 2)
        {
          int row_wb = row_wb_1 + (local_id % 4) / 2 * 8;
          if (row_wb < M){
            int col_wb = col_wb_1 + (local_id / 4) * 8 + (local_id % 2);
            float2 wscale = __half22float2(*(wscales + col_wb / 2));
            float ascale = __half2float(ascales[row_wb]);
            float2 psums = make_float2(__int2float_rn(C_warp_local[local_id]), __int2float_rn(C_warp_local[local_id + 1]));
            psums.x *= wscale.x * ascale;
            psums.y *= wscale.y * ascale;
            *reinterpret_cast<half2 *>(C + row_wb * N + col_wb) = __float22half2_rn(psums);
          }
        };
      }
    }
  }
}

torch::Tensor w8a8_gemm_forward_cuda(torch::Tensor _in_feats,
                                torch::Tensor _kernel,
                                torch::Tensor _wscales,
                                torch::Tensor _ascales)
{
  int num_in_feats = _in_feats.size(0);
  int num_in_channels = _in_feats.size(1);
  auto in_feats = reinterpret_cast<int8_t *>(_in_feats.data_ptr<int8_t>());
  auto kernel = reinterpret_cast<int8_t *>(_kernel.data_ptr<int8_t>());
  auto wscales = reinterpret_cast<half2 *>(_wscales.data_ptr());
  auto ascales = reinterpret_cast<half *>(_ascales.data_ptr());
  auto options =
      torch::TensorOptions().dtype(torch::kFloat16).device(_in_feats.device());
  at::Tensor _out_feats =
      torch::empty({num_in_feats, _kernel.size(0)}, options);
  int num_out_feats = _out_feats.size(-2);
  int num_out_channels = _out_feats.size(-1);


  auto out_feats = reinterpret_cast<half *>(_out_feats.data_ptr<at::Half>());

  if (num_out_feats > 128)
  {
    constexpr int CTA_M = 128;
    constexpr int CTA_N = 256;
    constexpr int CTA_K = 64;
    constexpr int WARP_M = 128;
    constexpr int WARP_N = 32;
    constexpr int WARP_K = 64;
    constexpr int STAGES = 3;
    KERNEL_LAUNCH_CODE
  }
  else 
  {
    constexpr int CTA_M = 64;
    constexpr int CTA_N = 64;
    constexpr int CTA_K = 64;
    constexpr int WARP_M = 32;
    constexpr int WARP_N = 32;
    constexpr int WARP_K = 64;
    constexpr int STAGES = 6;
    KERNEL_LAUNCH_CODE
  }
  
  return _out_feats;
}

